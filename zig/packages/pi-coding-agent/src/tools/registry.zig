const std = @import("std");
const common = @import("common.zig");
const read = @import("read.zig");
const bash = @import("bash.zig");
const write_tool = @import("write.zig");
const edit = @import("edit.zig");
const grep = @import("grep.zig");
const find = @import("find.zig");
const ls = @import("ls.zig");

pub const BuiltinToolCatalog = struct {
    pub const all: []const type = &.{
        read.ReadTool,
        bash.BashTool,
        write_tool.WriteTool,
        edit.EditTool,
        grep.GrepTool,
        find.FindTool,
        ls.LsTool,
    };
};

pub fn forEachBuiltin(comptime ctx: anytype, comptime callback: fn (comptime ctx: @TypeOf(ctx), comptime T: type) void) void {
    inline for (BuiltinToolCatalog.all) |ToolT| {
        callback(ctx, ToolT);
    }
}

pub fn validateNoDuplicateNames() !void {
    inline for (BuiltinToolCatalog.all, 0..) |ToolT, i| {
        inline for (BuiltinToolCatalog.all[i + 1 ..]) |OtherToolT| {
            if (std.mem.eql(u8, ToolT.name, OtherToolT.name)) {
                std.debug.print("duplicate built-in tool name: {s}\n", .{ToolT.name});
                return error.DuplicateBuiltinToolName;
            }
        }
    }
}

pub fn schemaFor(allocator: std.mem.Allocator, name: []const u8) !std.json.Value {
    inline for (BuiltinToolCatalog.all) |ToolT| {
        if (std.mem.eql(u8, ToolT.name, name)) {
            return try ToolT.schema(allocator);
        }
    }
    return error.UnknownBuiltinTool;
}

test "builtin tool catalog validates unique names" {
    try validateNoDuplicateNames();
}

test "schemaFor returns schema for known built-in tool" {
    const schema = try schemaFor(std.testing.allocator, "read");
    defer common.deinitJsonValue(std.testing.allocator, schema);

    try std.testing.expectEqualStrings("object", schema.object.get("type").?.string);
}

test "schemaFor rejects unknown built-in tool" {
    try std.testing.expectError(error.UnknownBuiltinTool, schemaFor(std.testing.allocator, "missing-tool"));
}
