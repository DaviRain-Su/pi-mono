const std = @import("std");
const common = @import("common.zig");

/// Validation constraint applied to integer fields parsed from JSON.
/// Tools can override the default (`.non_negative`) per-field via
/// `pub const json_int_constraints = .{ .field_name = .positive };`.
pub const IntConstraint = enum {
    /// Accept any non-negative integer that fits in the field type.
    non_negative,
    /// Require the integer to be strictly greater than zero.
    positive,
};

/// Comptime, reflection-driven JSON-to-Args parser shared by all built-in tools.
///
/// Supported field types: `[]const u8`, `bool`, signed/unsigned integers,
/// and `?T` of any of those. Required fields are bare (no default); optional
/// fields are either `?T` or carry a default value in the struct declaration.
///
/// Per-field metadata declared as struct decls on `T` (optional):
///   * `pub const json_aliases = .{ .field_name = .{ "alias1", "alias2", ... } };`
///     The first alias that resolves in the JSON object wins.
///   * `pub const json_int_constraints = .{ .field_name = .positive };`
///   * `pub const json_owned = .{ .field_a, .field_b };`
///     Each named field (must be `[]const u8` or `?[]const u8`) is
///     `allocator.dupe`d off the JSON tree so the resulting Args can
///     outlive the parse tree. On error mid-parse, already-duped fields
///     are freed automatically. Callers that consumed Args successfully
///     should release the duped strings via `deinitOwnedArgs`.
///
/// Note: a `json_owned` entry that names a non-existent field, or names
/// a field whose type is not `[]const u8` / `?[]const u8`, is a compile
/// error (caught by `checkOwnedFields`).
pub fn parseArgsFromJson(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !T {
    comptime checkOwnedFields(T);
    if (value != .object) return error.InvalidToolArguments;
    const object = value.object;

    const owned_count = comptime ownedFieldCount(T);
    // When `owned_count == 0` we still need a real slice so the errdefer
    // arithmetic compiles; an empty slot array is fine.
    var owned_slots: [if (owned_count == 0) 1 else owned_count][]u8 = undefined;
    var owned_used: usize = 0;
    errdefer {
        if (owned_count > 0) {
            var i: usize = 0;
            while (i < owned_used) : (i += 1) allocator.free(owned_slots[i]);
        }
    }

    const fields = @typeInfo(T).@"struct".fields;
    var result: T = undefined;
    inline for (fields) |field| {
        const FieldT = field.type;
        const constraint = comptime fieldIntConstraint(T, field.name);

        var raw: ?std.json.Value = null;
        if (comptime hasAliasDecl(T, field.name)) {
            const aliases_tuple = @field(T.json_aliases, field.name);
            inline for (@typeInfo(@TypeOf(aliases_tuple)).@"struct".fields) |alias_f| {
                if (raw == null) {
                    const alias_value = @field(aliases_tuple, alias_f.name);
                    if (object.get(alias_value)) |v| {
                        if (v != .null) raw = v;
                    }
                }
            }
        } else if (object.get(field.name)) |v| {
            if (v != .null) raw = v;
        }

        if (raw) |raw_val| {
            const extracted = try extractField(FieldT, raw_val, constraint);
            if (comptime isOwnedField(T, field.name)) {
                if (comptime @typeInfo(FieldT) == .optional) {
                    if (extracted) |s| {
                        const duped = try allocator.dupe(u8, s);
                        owned_slots[owned_used] = duped;
                        owned_used += 1;
                        @field(result, field.name) = duped;
                    } else {
                        @field(result, field.name) = null;
                    }
                } else {
                    const duped = try allocator.dupe(u8, extracted);
                    owned_slots[owned_used] = duped;
                    owned_used += 1;
                    @field(result, field.name) = duped;
                }
            } else {
                @field(result, field.name) = extracted;
            }
        } else if (comptime field.defaultValue() != null) {
            @field(result, field.name) = comptime field.defaultValue().?;
        } else if (comptime @typeInfo(FieldT) == .optional) {
            @field(result, field.name) = null;
        } else {
            return error.InvalidToolArguments;
        }
    }
    return result;
}

/// Free the strings duped into Args by `parseArgsFromJson` per `json_owned`.
/// Safe to call on Args whose `T` does not declare `json_owned` (no-op).
pub fn deinitOwnedArgs(comptime T: type, allocator: std.mem.Allocator, args: T) void {
    comptime checkOwnedFields(T);
    if (!@hasDecl(T, "json_owned")) return;
    const owned_tuple = T.json_owned;
    inline for (@typeInfo(@TypeOf(owned_tuple)).@"struct".fields) |tf| {
        const name = comptime @tagName(@field(owned_tuple, tf.name));
        const FieldT = comptime fieldType(T, name);
        if (comptime @typeInfo(FieldT) == .optional) {
            if (@field(args, name)) |s| allocator.free(s);
        } else {
            allocator.free(@field(args, name));
        }
    }
}

fn hasAliasDecl(comptime T: type, comptime name: [:0]const u8) bool {
    if (!@hasDecl(T, "json_aliases")) return false;
    return @hasField(@TypeOf(T.json_aliases), name);
}

fn fieldIntConstraint(comptime T: type, comptime name: [:0]const u8) IntConstraint {
    if (!@hasDecl(T, "json_int_constraints")) return .non_negative;
    const decls = T.json_int_constraints;
    if (!@hasField(@TypeOf(decls), name)) return .non_negative;
    return @field(decls, name);
}

fn fieldType(comptime T: type, comptime name: []const u8) type {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, name)) return f.type;
    }
    @compileError("parseArgsFromJson: field '" ++ name ++ "' not found on " ++ @typeName(T));
}

fn isOwnedField(comptime T: type, comptime name: []const u8) bool {
    if (!@hasDecl(T, "json_owned")) return false;
    const owned_tuple = T.json_owned;
    inline for (@typeInfo(@TypeOf(owned_tuple)).@"struct".fields) |tf| {
        const candidate = @tagName(@field(owned_tuple, tf.name));
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn ownedFieldCount(comptime T: type) usize {
    if (!@hasDecl(T, "json_owned")) return 0;
    return @typeInfo(@TypeOf(T.json_owned)).@"struct".fields.len;
}

fn checkOwnedFields(comptime T: type) void {
    if (!@hasDecl(T, "json_owned")) return;
    const owned_tuple = T.json_owned;
    inline for (@typeInfo(@TypeOf(owned_tuple)).@"struct".fields) |tf| {
        const name = @tagName(@field(owned_tuple, tf.name));
        var found = false;
        inline for (@typeInfo(T).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, name)) {
                found = true;
                const FieldT = f.type;
                const ok = switch (@typeInfo(FieldT)) {
                    .pointer => |ptr| ptr.size == .slice and ptr.child == u8,
                    .optional => |opt| switch (@typeInfo(opt.child)) {
                        .pointer => |ptr| ptr.size == .slice and ptr.child == u8,
                        else => false,
                    },
                    else => false,
                };
                if (!ok) {
                    @compileError("json_owned: field '" ++ name ++ "' on " ++ @typeName(T) ++ " must be []const u8 or ?[]const u8");
                }
            }
        }
        if (!found) {
            @compileError("json_owned: field '" ++ name ++ "' does not exist on " ++ @typeName(T));
        }
    }
}

fn extractField(comptime FieldT: type, value: std.json.Value, constraint: IntConstraint) !FieldT {
    switch (@typeInfo(FieldT)) {
        .optional => |opt| return try extractField(opt.child, value, constraint),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                if (value != .string) return error.InvalidToolArguments;
                return value.string;
            }
            @compileError("parseArgsFromJson: unsupported pointer field type " ++ @typeName(FieldT));
        },
        .bool => {
            if (value != .bool) return error.InvalidToolArguments;
            return value.bool;
        },
        .int => {
            if (value != .integer) return error.InvalidToolArguments;
            switch (constraint) {
                .positive => if (value.integer <= 0) return error.InvalidToolArguments,
                .non_negative => if (value.integer < 0) return error.InvalidToolArguments,
            }
            return std.math.cast(FieldT, value.integer) orelse error.InvalidToolArguments;
        },
        else => @compileError("parseArgsFromJson: unsupported field type " ++ @typeName(FieldT)),
    }
}

// ---- Tests ----

fn putString(object: *std.json.ObjectMap, key: []const u8, val: []const u8) !void {
    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, key), .{ .string = try std.testing.allocator.dupe(u8, val) });
}

fn putBool(object: *std.json.ObjectMap, key: []const u8, val: bool) !void {
    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, key), .{ .bool = val });
}

fn putInt(object: *std.json.ObjectMap, key: []const u8, val: i64) !void {
    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, key), .{ .integer = val });
}

fn freeObject(object: std.json.ObjectMap) void {
    const value = std.json.Value{ .object = object };
    common.deinitJsonValue(std.testing.allocator, value);
}

test "parseArgsFromJson required string + optional positive integers" {
    const Args = struct {
        path: []const u8,
        offset: ?usize = null,
        limit: ?usize = null,

        pub const json_int_constraints = .{
            .offset = .positive,
            .limit = .positive,
        };
    };

    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    try putString(&object, "path", "file.txt");
    try putInt(&object, "limit", 5);
    defer freeObject(object);

    const parsed = try parseArgsFromJson(Args, std.testing.allocator, .{ .object = object });
    try std.testing.expectEqualStrings("file.txt", parsed.path);
    try std.testing.expectEqual(@as(?usize, null), parsed.offset);
    try std.testing.expectEqual(@as(?usize, 5), parsed.limit);
}

test "parseArgsFromJson rejects missing required field" {
    const Args = struct { path: []const u8 };
    const object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    defer freeObject(object);
    try std.testing.expectError(error.InvalidToolArguments, parseArgsFromJson(Args, std.testing.allocator, .{ .object = object }));
}

test "parseArgsFromJson rejects non-positive integer when constraint is .positive" {
    const Args = struct {
        offset: ?usize = null,
        pub const json_int_constraints = .{ .offset = .positive };
    };
    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    try putInt(&object, "offset", 0);
    defer freeObject(object);
    try std.testing.expectError(error.InvalidToolArguments, parseArgsFromJson(Args, std.testing.allocator, .{ .object = object }));
}

test "parseArgsFromJson rejects negative integer" {
    const Args = struct {
        context: usize = 0,
    };
    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    try putInt(&object, "context", -1);
    defer freeObject(object);
    try std.testing.expectError(error.InvalidToolArguments, parseArgsFromJson(Args, std.testing.allocator, .{ .object = object }));
}

test "parseArgsFromJson resolves aliases in declaration order" {
    const Args = struct {
        glob: ?[]const u8 = null,
        ignore_case: bool = false,

        pub const json_aliases = .{
            .glob = .{ "glob", "glob_pattern" },
            .ignore_case = .{ "ignoreCase", "ignore_case" },
        };
    };

    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    try putString(&object, "glob_pattern", "*.zig");
    try putBool(&object, "ignoreCase", true);
    defer freeObject(object);

    const parsed = try parseArgsFromJson(Args, std.testing.allocator, .{ .object = object });
    try std.testing.expectEqualStrings("*.zig", parsed.glob.?);
    try std.testing.expectEqual(true, parsed.ignore_case);
}

test "parseArgsFromJson alias resolves first match" {
    const Args = struct {
        glob: ?[]const u8 = null,
        pub const json_aliases = .{ .glob = .{ "glob", "glob_pattern" } };
    };
    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    try putString(&object, "glob", "first");
    try putString(&object, "glob_pattern", "second");
    defer freeObject(object);

    const parsed = try parseArgsFromJson(Args, std.testing.allocator, .{ .object = object });
    try std.testing.expectEqualStrings("first", parsed.glob.?);
}

test "parseArgsFromJson rejects non-object input" {
    const Args = struct { path: []const u8 };
    try std.testing.expectError(error.InvalidToolArguments, parseArgsFromJson(Args, std.testing.allocator, .{ .integer = 1 }));
}

test "parseArgsFromJson rejects type mismatch" {
    const Args = struct { path: []const u8 };
    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    defer freeObject(object);
    try putInt(&object, "path", 42);
    try std.testing.expectError(error.InvalidToolArguments, parseArgsFromJson(Args, std.testing.allocator, .{ .object = object }));
}

// Comptime guard sketch (intentionally not executed — would fail to compile):
//   const Bad = struct { count: usize, pub const json_owned = .{ .count }; };
//   _ = parseArgsFromJson(Bad, alloc, val);  // @compileError: must be []const u8 or ?[]const u8
//   const Missing = struct { path: []const u8, pub const json_owned = .{ .nope }; };
//   _ = parseArgsFromJson(Missing, alloc, val);  // @compileError: field does not exist

test "parseArgsFromJson dupes json_owned fields independently of JSON tree" {
    const Args = struct {
        path: []const u8,
        pub const json_owned = .{.path};
    };

    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    try putString(&object, "path", "original.txt");

    const parsed = try parseArgsFromJson(Args, std.testing.allocator, .{ .object = object });
    defer deinitOwnedArgs(Args, std.testing.allocator, parsed);

    // Tear down the JSON tree; the duped path must still be valid.
    freeObject(object);

    try std.testing.expectEqualStrings("original.txt", parsed.path);
}

test "deinitOwnedArgs frees json_owned strings (no leak)" {
    const Args = struct {
        path: []const u8,
        other: ?[]const u8 = null,
        pub const json_owned = .{ .path, .other };
    };

    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    try putString(&object, "path", "a.zig");
    try putString(&object, "other", "b.zig");
    defer freeObject(object);

    const parsed = try parseArgsFromJson(Args, std.testing.allocator, .{ .object = object });
    deinitOwnedArgs(Args, std.testing.allocator, parsed);
    // testing.allocator will assert no leaks on test teardown
}

test "parseArgsFromJson errdefer frees partial json_owned on later field failure" {
    const Args = struct {
        path: []const u8,
        other: []const u8,
        pub const json_owned = .{ .path, .other };
    };

    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    defer freeObject(object);
    try putString(&object, "path", "ok.zig");
    // `other` field is a wrong type; this forces failure AFTER `path` was duped.
    try putInt(&object, "other", 7);

    try std.testing.expectError(
        error.InvalidToolArguments,
        parseArgsFromJson(Args, std.testing.allocator, .{ .object = object }),
    );
    // testing.allocator will fail the test if the partial `path` dupe leaked.
}

test "optional ?[]const u8 json_owned field handles null without alloc" {
    const Args = struct {
        path: []const u8,
        other: ?[]const u8 = null,
        pub const json_owned = .{ .path, .other };
    };

    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    try putString(&object, "path", "p.zig");
    defer freeObject(object);

    const parsed = try parseArgsFromJson(Args, std.testing.allocator, .{ .object = object });
    defer deinitOwnedArgs(Args, std.testing.allocator, parsed);

    try std.testing.expectEqualStrings("p.zig", parsed.path);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.other);
}

test "deinitOwnedArgs is a no-op when T has no json_owned decl" {
    const Args = struct { path: []const u8 };
    // Just verify it compiles and runs without freeing anything.
    deinitOwnedArgs(Args, std.testing.allocator, .{ .path = "static" });
}
