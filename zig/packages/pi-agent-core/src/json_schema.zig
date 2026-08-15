const std = @import("std");

pub const SchemaValidationIssue = struct {
    code: []const u8,
    message: []const u8,
    path: []const u8,

    pub fn deinit(self: SchemaValidationIssue, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.message);
        allocator.free(self.path);
    }
};

pub fn validateToolArguments(
    allocator: std.mem.Allocator,
    schema: std.json.Value,
    args: std.json.Value,
) std.mem.Allocator.Error!?SchemaValidationIssue {
    var path = std.ArrayList(u8).empty;
    defer path.deinit(allocator);
    try path.appendSlice(allocator, "$");
    return try validateValue(.detailed, allocator, schema, args, &path);
}

const Mode = enum { quick, detailed };

fn ResultType(comptime mode: Mode) type {
    return switch (mode) {
        .quick => anyerror!void,
        .detailed => std.mem.Allocator.Error!?SchemaValidationIssue,
    };
}

const SchemaKind = enum { object, string, boolean, integer, number, array };

const SCHEMA_KIND_MAP = std.StaticStringMap(SchemaKind).initComptime(.{
    .{ "object", SchemaKind.object },
    .{ "string", SchemaKind.string },
    .{ "boolean", SchemaKind.boolean },
    .{ "integer", SchemaKind.integer },
    .{ "number", SchemaKind.number },
    .{ "array", SchemaKind.array },
});

fn ok(comptime mode: Mode) ResultType(mode) {
    switch (comptime mode) {
        .quick => return,
        .detailed => return null,
    }
}

fn fail(
    comptime mode: Mode,
    allocator: std.mem.Allocator,
    path: []const u8,
    code: []const u8,
    message: []const u8,
) ResultType(mode) {
    switch (comptime mode) {
        .quick => return error.InvalidToolArguments,
        .detailed => return try schemaIssue(allocator, path, code, message),
    }
}

fn validateValue(
    comptime mode: Mode,
    allocator: std.mem.Allocator,
    schema: std.json.Value,
    value: std.json.Value,
    path: *std.ArrayList(u8),
) ResultType(mode) {
    if (schema != .object) return ok(mode);
    if (schema.object.get("type")) |type_value| {
        if (type_value == .string) {
            return validateKind(mode, allocator, type_value.string, schema, value, path);
        }
    }
    return ok(mode);
}

fn validateKind(
    comptime mode: Mode,
    allocator: std.mem.Allocator,
    type_name: []const u8,
    schema: std.json.Value,
    value: std.json.Value,
    path: *std.ArrayList(u8),
) ResultType(mode) {
    const kind = SCHEMA_KIND_MAP.get(type_name) orelse return ok(mode);
    switch (kind) {
        .object => return try validateObject(mode, allocator, schema, value, path),
        .string => {
            if (value != .string) return try fail(mode, allocator, path.items, "invalid_type", "expected string");
            return ok(mode);
        },
        .boolean => {
            if (value != .bool) return try fail(mode, allocator, path.items, "invalid_type", "expected boolean");
            return ok(mode);
        },
        .integer => {
            if (value != .integer) return try fail(mode, allocator, path.items, "invalid_type", "expected integer");
            return ok(mode);
        },
        .number => {
            if (value != .integer and value != .float and value != .number_string) {
                return try fail(mode, allocator, path.items, "invalid_type", "expected number");
            }
            return ok(mode);
        },
        .array => return try validateArray(mode, allocator, schema, value, path),
    }
}

fn validateObject(
    comptime mode: Mode,
    allocator: std.mem.Allocator,
    schema: std.json.Value,
    value: std.json.Value,
    path: *std.ArrayList(u8),
) ResultType(mode) {
    if (value != .object) return try fail(mode, allocator, path.items, "invalid_type", "expected object");
    if (schema.object.get("required")) |required| {
        if (required == .array) {
            for (required.array.items) |required_item| {
                if (required_item != .string) continue;
                if (!value.object.contains(required_item.string)) {
                    switch (comptime mode) {
                        .quick => return error.InvalidToolArguments,
                        .detailed => {
                            const original_len = path.items.len;
                            try appendPathProperty(allocator, path, required_item.string);
                            defer path.shrinkRetainingCapacity(original_len);
                            return try schemaIssue(allocator, path.items, "missing_required", "missing required field");
                        },
                    }
                }
            }
        }
    }
    const properties = if (schema.object.get("properties")) |properties_value| switch (properties_value) {
        .object => |properties_object| properties_object,
        else => null,
    } else null;
    if (properties) |properties_object| {
        var property_iterator = properties_object.iterator();
        while (property_iterator.next()) |entry| {
            if (value.object.get(entry.key_ptr.*)) |property_value| {
                switch (comptime mode) {
                    .quick => try validateValue(mode, allocator, entry.value_ptr.*, property_value, path),
                    .detailed => {
                        const original_len = path.items.len;
                        try appendPathProperty(allocator, path, entry.key_ptr.*);
                        defer path.shrinkRetainingCapacity(original_len);
                        if (try validateValue(mode, allocator, entry.value_ptr.*, property_value, path)) |issue| return issue;
                    },
                }
            }
        }
        if (schema.object.get("additionalProperties")) |additional_properties| {
            if (additional_properties == .bool and !additional_properties.bool) {
                var value_iterator = value.object.iterator();
                while (value_iterator.next()) |entry| {
                    if (!properties_object.contains(entry.key_ptr.*)) {
                        switch (comptime mode) {
                            .quick => return error.InvalidToolArguments,
                            .detailed => {
                                const original_len = path.items.len;
                                try appendPathProperty(allocator, path, entry.key_ptr.*);
                                defer path.shrinkRetainingCapacity(original_len);
                                return try schemaIssue(allocator, path.items, "additional_property", "unexpected field");
                            },
                        }
                    }
                }
            }
        }
    }
    return ok(mode);
}

fn validateArray(
    comptime mode: Mode,
    allocator: std.mem.Allocator,
    schema: std.json.Value,
    value: std.json.Value,
    path: *std.ArrayList(u8),
) ResultType(mode) {
    if (value != .array) return try fail(mode, allocator, path.items, "invalid_type", "expected array");
    if (schema.object.get("items")) |items_schema| {
        switch (comptime mode) {
            .quick => {
                for (value.array.items) |item| try validateValue(mode, allocator, items_schema, item, path);
            },
            .detailed => {
                for (value.array.items, 0..) |item, index| {
                    const original_len = path.items.len;
                    try appendPathIndex(allocator, path, index);
                    defer path.shrinkRetainingCapacity(original_len);
                    if (try validateValue(mode, allocator, items_schema, item, path)) |issue| return issue;
                }
            },
        }
    }
    return ok(mode);
}

fn appendPathProperty(allocator: std.mem.Allocator, path: *std.ArrayList(u8), property: []const u8) std.mem.Allocator.Error!void {
    try path.append(allocator, '.');
    try path.appendSlice(allocator, property);
}

fn appendPathIndex(allocator: std.mem.Allocator, path: *std.ArrayList(u8), index: usize) std.mem.Allocator.Error!void {
    var buffer: [32]u8 = undefined;
    const segment = std.fmt.bufPrint(&buffer, "[{d}]", .{index}) catch unreachable;
    try path.appendSlice(allocator, segment);
}

fn schemaIssue(
    allocator: std.mem.Allocator,
    path: []const u8,
    code: []const u8,
    message: []const u8,
) std.mem.Allocator.Error!SchemaValidationIssue {
    return .{
        .code = try allocator.dupe(u8, code),
        .message = try allocator.dupe(u8, message),
        .path = try allocator.dupe(u8, path),
    };
}

fn parseJson(allocator: std.mem.Allocator, source: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, source, .{});
}

test "validateToolArguments returns null when type matches" {
    const allocator = std.testing.allocator;
    var schema = try parseJson(allocator,
        \\{"type":"object","required":["name"],"properties":{"name":{"type":"string"}}}
    );
    defer schema.deinit();
    var args = try parseJson(allocator,
        \\{"name":"foo"}
    );
    defer args.deinit();
    const issue = try validateToolArguments(allocator, schema.value, args.value);
    try std.testing.expect(issue == null);
}

test "validateToolArguments flags missing required field with path" {
    const allocator = std.testing.allocator;
    var schema = try parseJson(allocator,
        \\{"type":"object","required":["name"],"properties":{"name":{"type":"string"}}}
    );
    defer schema.deinit();
    var args = try parseJson(allocator,
        \\{}
    );
    defer args.deinit();
    const issue_opt = try validateToolArguments(allocator, schema.value, args.value);
    try std.testing.expect(issue_opt != null);
    const issue = issue_opt.?;
    defer issue.deinit(allocator);
    try std.testing.expectEqualStrings("missing_required", issue.code);
    try std.testing.expectEqualStrings("missing required field", issue.message);
    try std.testing.expectEqualStrings("$.name", issue.path);
}

test "validateToolArguments flags wrong nested type with path" {
    const allocator = std.testing.allocator;
    var schema = try parseJson(allocator,
        \\{"type":"object","properties":{"age":{"type":"integer"}}}
    );
    defer schema.deinit();
    var args = try parseJson(allocator,
        \\{"age":"old"}
    );
    defer args.deinit();
    const issue_opt = try validateToolArguments(allocator, schema.value, args.value);
    try std.testing.expect(issue_opt != null);
    const issue = issue_opt.?;
    defer issue.deinit(allocator);
    try std.testing.expectEqualStrings("invalid_type", issue.code);
    try std.testing.expectEqualStrings("expected integer", issue.message);
    try std.testing.expectEqualStrings("$.age", issue.path);
}

test "validateToolArguments flags array item type with index path" {
    const allocator = std.testing.allocator;
    var schema = try parseJson(allocator,
        \\{"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"}}}}
    );
    defer schema.deinit();
    var args = try parseJson(allocator,
        \\{"tags":["a",42,"c"]}
    );
    defer args.deinit();
    const issue_opt = try validateToolArguments(allocator, schema.value, args.value);
    try std.testing.expect(issue_opt != null);
    const issue = issue_opt.?;
    defer issue.deinit(allocator);
    try std.testing.expectEqualStrings("invalid_type", issue.code);
    try std.testing.expectEqualStrings("expected string", issue.message);
    try std.testing.expectEqualStrings("$.tags[1]", issue.path);
}

test "validateToolArguments flags unexpected additional property" {
    const allocator = std.testing.allocator;
    var schema = try parseJson(allocator,
        \\{"type":"object","properties":{"name":{"type":"string"}},"additionalProperties":false}
    );
    defer schema.deinit();
    var args = try parseJson(allocator,
        \\{"name":"a","extra":1}
    );
    defer args.deinit();
    const issue_opt = try validateToolArguments(allocator, schema.value, args.value);
    try std.testing.expect(issue_opt != null);
    const issue = issue_opt.?;
    defer issue.deinit(allocator);
    try std.testing.expectEqualStrings("additional_property", issue.code);
    try std.testing.expectEqualStrings("$.extra", issue.path);
}

test "validateToolArguments accepts integer or float for number" {
    const allocator = std.testing.allocator;
    var schema = try parseJson(allocator,
        \\{"type":"object","properties":{"v":{"type":"number"}}}
    );
    defer schema.deinit();

    const inputs = [_][]const u8{
        \\{"v":1}
        ,
        \\{"v":1.5}
        ,
    };
    for (inputs) |src| {
        var args = try parseJson(allocator, src);
        defer args.deinit();
        const issue_opt = try validateToolArguments(allocator, schema.value, args.value);
        try std.testing.expect(issue_opt == null);
    }

    var bad = try parseJson(allocator,
        \\{"v":"nope"}
    );
    defer bad.deinit();
    const issue_opt = try validateToolArguments(allocator, schema.value, bad.value);
    try std.testing.expect(issue_opt != null);
    const issue = issue_opt.?;
    defer issue.deinit(allocator);
    try std.testing.expectEqualStrings("invalid_type", issue.code);
    try std.testing.expectEqualStrings("expected number", issue.message);
}

test "validateValue quick mode short-circuits with InvalidToolArguments" {
    const allocator = std.testing.allocator;
    var schema = try parseJson(allocator,
        \\{"type":"object","required":["name"],"properties":{"name":{"type":"string"}}}
    );
    defer schema.deinit();
    var args = try parseJson(allocator,
        \\{}
    );
    defer args.deinit();
    var path = std.ArrayList(u8).empty;
    defer path.deinit(allocator);
    try path.appendSlice(allocator, "$");
    const result = validateValue(.quick, allocator, schema.value, args.value, &path);
    try std.testing.expectError(error.InvalidToolArguments, result);
}

test "validateValue quick mode accepts valid input" {
    const allocator = std.testing.allocator;
    var schema = try parseJson(allocator,
        \\{"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"}}}}
    );
    defer schema.deinit();
    var args = try parseJson(allocator,
        \\{"tags":["a","b"]}
    );
    defer args.deinit();
    var path = std.ArrayList(u8).empty;
    defer path.deinit(allocator);
    try path.appendSlice(allocator, "$");
    try validateValue(.quick, allocator, schema.value, args.value, &path);
}

test "validateValue unknown type string is treated as no-op in both modes" {
    const allocator = std.testing.allocator;
    var schema = try parseJson(allocator,
        \\{"type":"weird"}
    );
    defer schema.deinit();
    var args = try parseJson(allocator,
        \\123
    );
    defer args.deinit();
    var path = std.ArrayList(u8).empty;
    defer path.deinit(allocator);
    try path.appendSlice(allocator, "$");
    try validateValue(.quick, allocator, schema.value, args.value, &path);
    const issue = try validateValue(.detailed, allocator, schema.value, args.value, &path);
    try std.testing.expect(issue == null);
}
