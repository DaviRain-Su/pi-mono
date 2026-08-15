const std = @import("std");

pub const JSON_REPAIR_MAX_INPUT_BYTES: usize = 64 * 1024;
pub const JSON_REPAIR_MAX_WORK_UNITS: usize = 512 * 1024;
pub const JSON_REPAIR_MAX_NESTING_DEPTH: usize = 64;

const parse_options: std.json.ParseOptions = .{ .allocate = .alloc_always };
const PartialParseError = error{ OutOfMemory, LimitExceeded };
const JSON_REPAIR_VALUE_WORK_UNITS: usize = 32;

/// Parse a complete JSON value, retrying once after applying the same repair
/// pass used by TypeScript's `parseJsonWithRepair`.
pub fn parseJsonWithRepair(allocator: std.mem.Allocator, input: []const u8) !std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len > JSON_REPAIR_MAX_INPUT_BYTES) return error.LimitExceeded;
    if (try exceedsStreamingJsonLimits(allocator, trimmed)) return error.LimitExceeded;

    if (std.json.parseFromSlice(std.json.Value, allocator, trimmed, parse_options)) |parsed| {
        return parsed;
    } else |parse_err| {
        const repaired = try repairJson(allocator, trimmed);
        defer allocator.free(repaired);

        if (!std.mem.eql(u8, repaired, trimmed)) {
            if (std.json.parseFromSlice(std.json.Value, allocator, repaired, parse_options)) |parsed| {
                return parsed;
            } else |_| {}
        }

        return parse_err;
    }
}

/// Parse a JSON string, handling incomplete/partial JSON gracefully.
/// Returns a parsed JSON value (caller must call `.deinit()` on the result).
pub fn parseStreamingJson(allocator: std.mem.Allocator, input: ?[]const u8) !std.json.Parsed(std.json.Value) {
    if (input == null or input.?.len == 0) {
        return parseEmptyObject(allocator);
    }

    if (input.?.len > JSON_REPAIR_MAX_INPUT_BYTES) {
        return parseEmptyObject(allocator);
    }

    const trimmed = std.mem.trim(u8, input.?, " \t\r\n");
    if (trimmed.len == 0) {
        return parseEmptyObject(allocator);
    }

    if (try exceedsStreamingJsonLimits(allocator, trimmed)) {
        return parseEmptyObject(allocator);
    }

    const repaired = try repairJson(allocator, trimmed);
    defer allocator.free(repaired);

    if (std.json.parseFromSlice(std.json.Value, allocator, repaired, parse_options)) |parsed| {
        return parsed;
    } else |_| {
        if (try parsePartialCandidate(allocator, trimmed)) |parsed| {
            return parsed;
        }
        if (!std.mem.eql(u8, repaired, trimmed)) {
            if (try parsePartialCandidate(allocator, repaired)) |parsed| {
                return parsed;
            }
        }

        return parseEmptyObject(allocator);
    }
}

fn parseEmptyObject(allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, "{}", parse_options);
}

fn parsePartialCandidate(allocator: std.mem.Allocator, input: []const u8) !?std.json.Parsed(std.json.Value) {
    const partial = repairPartialJson(allocator, input) catch |err| switch (err) {
        error.LimitExceeded => return null,
        else => |other| return other,
    };
    defer allocator.free(partial);

    if (partial.len == 0) return null;
    if (std.json.parseFromSlice(std.json.Value, allocator, partial, parse_options)) |parsed| {
        return parsed;
    } else |_| {
        return null;
    }
}

fn exceedsStreamingJsonLimits(allocator: std.mem.Allocator, input: []const u8) !bool {
    var parser = PartialParser{
        .allocator = allocator,
        .input = input,
    };
    var parsed_prefix = std.ArrayList(u8).empty;
    defer parsed_prefix.deinit(allocator);

    _ = parser.parseValue(&parsed_prefix) catch |err| switch (err) {
        error.LimitExceeded => return true,
        else => |other| return other,
    };
    parser.skipWhitespace() catch |err| switch (err) {
        error.LimitExceeded => return true,
        else => |other| return other,
    };
    return false;
}

fn repairJson(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var repaired = std.ArrayList(u8).empty;
    errdefer repaired.deinit(allocator);

    var in_string = false;
    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        const char = input[index];

        if (!in_string) {
            try repaired.append(allocator, char);
            if (char == '"') in_string = true;
            continue;
        }

        if (char == '"') {
            try repaired.append(allocator, char);
            in_string = false;
            continue;
        }

        if (char == '\\') {
            if (index + 1 >= input.len) {
                try repaired.appendSlice(allocator, "\\\\");
                continue;
            }

            const next = input[index + 1];
            if (next == 'u' and index + 5 < input.len and isHexSlice(input[index + 2 .. index + 6])) {
                try repaired.appendSlice(allocator, input[index .. index + 6]);
                index += 5;
                continue;
            }

            if (isValidJsonEscape(next)) {
                try repaired.appendSlice(allocator, input[index .. index + 2]);
                index += 1;
                continue;
            }

            try repaired.appendSlice(allocator, "\\\\");
            continue;
        }

        if (char <= 0x1f) {
            try appendEscapedControl(&repaired, allocator, char);
        } else {
            try repaired.append(allocator, char);
        }
    }

    return repaired.toOwnedSlice(allocator);
}

fn isValidJsonEscape(char: u8) bool {
    return switch (char) {
        '"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u' => true,
        else => false,
    };
}

fn isHexSlice(bytes: []const u8) bool {
    if (bytes.len != 4) return false;
    for (bytes) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn appendEscapedControl(out: *std.ArrayList(u8), allocator: std.mem.Allocator, char: u8) !void {
    switch (char) {
        '\x08' => try out.appendSlice(allocator, "\\b"),
        '\x0c' => try out.appendSlice(allocator, "\\f"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => {
            var buffer: [6]u8 = undefined;
            const escaped = try std.fmt.bufPrint(&buffer, "\\u{x:0>4}", .{char});
            try out.appendSlice(allocator, escaped);
        },
    }
}

fn repairPartialJson(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var parser = PartialParser{
        .allocator = allocator,
        .input = input,
    };
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    if (!try parser.parseValue(&out)) {
        out.clearRetainingCapacity();
    }

    return out.toOwnedSlice(allocator);
}

const PartialParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,
    work_units: usize = 0,
    depth: usize = 0,

    fn consume(self: *PartialParser) PartialParseError!u8 {
        try self.bumpWork();
        const byte = self.input[self.index];
        self.index += 1;
        return byte;
    }

    fn bumpWork(self: *PartialParser) PartialParseError!void {
        try self.bumpWorkCost(1);
    }

    fn bumpWorkCost(self: *PartialParser, units: usize) PartialParseError!void {
        self.work_units = std.math.add(usize, self.work_units, units) catch return error.LimitExceeded;
        if (self.work_units > JSON_REPAIR_MAX_WORK_UNITS) return error.LimitExceeded;
    }

    fn skipWhitespace(self: *PartialParser) PartialParseError!void {
        while (self.index < self.input.len) {
            switch (self.input[self.index]) {
                ' ', '\t', '\r', '\n' => {
                    _ = try self.consume();
                },
                else => return,
            }
        }
    }

    fn parseValue(self: *PartialParser, out: *std.ArrayList(u8)) PartialParseError!bool {
        try self.bumpWorkCost(JSON_REPAIR_VALUE_WORK_UNITS);
        try self.skipWhitespace();
        if (self.index >= self.input.len) return false;

        return switch (self.input[self.index]) {
            '{' => self.parseObject(out),
            '[' => self.parseArray(out),
            '"' => self.parseString(out, true),
            '-', '0'...'9' => self.parseNumber(out),
            't' => self.parseLiteral(out, "true"),
            'f' => self.parseLiteral(out, "false"),
            'n' => self.parseLiteral(out, "null"),
            else => false,
        };
    }

    fn parseObject(self: *PartialParser, out: *std.ArrayList(u8)) PartialParseError!bool {
        if (self.depth >= JSON_REPAIR_MAX_NESTING_DEPTH) return error.LimitExceeded;
        self.depth += 1;
        defer self.depth -= 1;

        _ = try self.consume();
        try out.append(self.allocator, '{');

        var member_count: usize = 0;
        while (true) {
            try self.skipWhitespace();
            if (self.index >= self.input.len) {
                try out.append(self.allocator, '}');
                return true;
            }
            if (self.input[self.index] == '}') {
                _ = try self.consume();
                try out.append(self.allocator, '}');
                return true;
            }
            if (self.input[self.index] != '"') {
                if (member_count == 0) return false;
                try out.append(self.allocator, '}');
                return true;
            }

            var key = std.ArrayList(u8).empty;
            defer key.deinit(self.allocator);
            if (!try self.parseString(&key, false)) {
                try out.append(self.allocator, '}');
                return true;
            }

            try self.skipWhitespace();
            if (self.index >= self.input.len or self.input[self.index] != ':') {
                try out.append(self.allocator, '}');
                return true;
            }
            _ = try self.consume();

            var value = std.ArrayList(u8).empty;
            defer value.deinit(self.allocator);
            if (!try self.parseValue(&value)) {
                try out.append(self.allocator, '}');
                return true;
            }

            if (member_count > 0) try out.append(self.allocator, ',');
            try out.appendSlice(self.allocator, key.items);
            try out.append(self.allocator, ':');
            try out.appendSlice(self.allocator, value.items);
            member_count += 1;

            try self.skipWhitespace();
            if (self.index >= self.input.len) {
                try out.append(self.allocator, '}');
                return true;
            }
            switch (self.input[self.index]) {
                ',' => {
                    _ = try self.consume();
                    continue;
                },
                '}' => {
                    _ = try self.consume();
                    try out.append(self.allocator, '}');
                    return true;
                },
                else => {
                    try out.append(self.allocator, '}');
                    return true;
                },
            }
        }
    }

    fn parseArray(self: *PartialParser, out: *std.ArrayList(u8)) PartialParseError!bool {
        if (self.depth >= JSON_REPAIR_MAX_NESTING_DEPTH) return error.LimitExceeded;
        self.depth += 1;
        defer self.depth -= 1;

        _ = try self.consume();
        try out.append(self.allocator, '[');

        var item_count: usize = 0;
        while (true) {
            try self.skipWhitespace();
            if (self.index >= self.input.len) {
                try out.append(self.allocator, ']');
                return true;
            }
            if (self.input[self.index] == ']') {
                _ = try self.consume();
                try out.append(self.allocator, ']');
                return true;
            }

            var value = std.ArrayList(u8).empty;
            defer value.deinit(self.allocator);
            if (!try self.parseValue(&value)) {
                try out.append(self.allocator, ']');
                return true;
            }

            if (item_count > 0) try out.append(self.allocator, ',');
            try out.appendSlice(self.allocator, value.items);
            item_count += 1;

            try self.skipWhitespace();
            if (self.index >= self.input.len) {
                try out.append(self.allocator, ']');
                return true;
            }
            switch (self.input[self.index]) {
                ',' => {
                    _ = try self.consume();
                    continue;
                },
                ']' => {
                    _ = try self.consume();
                    try out.append(self.allocator, ']');
                    return true;
                },
                else => {
                    try out.append(self.allocator, ']');
                    return true;
                },
            }
        }
    }

    fn parseString(self: *PartialParser, out: *std.ArrayList(u8), allow_partial: bool) PartialParseError!bool {
        if (self.input[self.index] != '"') return false;
        _ = try self.consume();
        try out.append(self.allocator, '"');

        while (self.index < self.input.len) {
            const char = try self.consume();
            if (char == '"') {
                try out.append(self.allocator, '"');
                return true;
            }
            if (char == '\\') {
                if (self.index >= self.input.len) {
                    if (!allow_partial) return false;
                    try out.append(self.allocator, '"');
                    return true;
                }
                const next = try self.consume();
                try out.append(self.allocator, '\\');
                try out.append(self.allocator, next);
                continue;
            }
            try out.append(self.allocator, char);
        }

        if (!allow_partial) return false;
        try out.append(self.allocator, '"');
        return true;
    }

    fn parseNumber(self: *PartialParser, out: *std.ArrayList(u8)) PartialParseError!bool {
        const start = self.index;
        if (self.input[self.index] == '-') _ = try self.consume();

        const int_start = self.index;
        while (self.index < self.input.len and self.input[self.index] >= '0' and self.input[self.index] <= '9') {
            _ = try self.consume();
        }
        if (self.index == int_start) return false;

        if (self.index < self.input.len and self.input[self.index] == '.') {
            const before_dot = self.index;
            _ = try self.consume();
            const frac_start = self.index;
            while (self.index < self.input.len and self.input[self.index] >= '0' and self.input[self.index] <= '9') {
                _ = try self.consume();
            }
            if (self.index == frac_start) self.index = before_dot;
        }

        if (self.index < self.input.len and (self.input[self.index] == 'e' or self.input[self.index] == 'E')) {
            const before_exp = self.index;
            _ = try self.consume();
            if (self.index < self.input.len and (self.input[self.index] == '+' or self.input[self.index] == '-')) {
                _ = try self.consume();
            }
            const exp_start = self.index;
            while (self.index < self.input.len and self.input[self.index] >= '0' and self.input[self.index] <= '9') {
                _ = try self.consume();
            }
            if (self.index == exp_start) self.index = before_exp;
        }

        try out.appendSlice(self.allocator, self.input[start..self.index]);
        return true;
    }

    fn parseLiteral(self: *PartialParser, out: *std.ArrayList(u8), literal: []const u8) PartialParseError!bool {
        if (self.input.len - self.index < literal.len) return false;
        if (!std.mem.eql(u8, self.input[self.index .. self.index + literal.len], literal)) return false;
        for (literal) |_| _ = try self.consume();
        try out.appendSlice(self.allocator, literal);
        return true;
    }
};

fn assertParsedJsonEquals(allocator: std.mem.Allocator, input: ?[]const u8, expected: []const u8) !void {
    var parsed = try parseStreamingJson(allocator, input);
    defer parsed.deinit();

    const actual = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectFixtureString(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = object.get(field) orelse return error.MissingFixtureField;
    if (value != .string) return error.InvalidFixtureField;
    return value.string;
}

fn expectOptionalFixtureInput(object: std.json.ObjectMap) !?[]const u8 {
    const value = object.get("input") orelse return error.MissingFixtureField;
    return switch (value) {
        .null => null,
        .string => value.string,
        else => error.InvalidFixtureField,
    };
}

test "parseStreamingJson matches TypeScript-generated repair fixtures" {
    const allocator = std.testing.allocator;
    const fixture_bytes = try std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        "test/golden/json-parse/cases.jsonl",
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(fixture_bytes);

    var lines = std.mem.splitScalar(u8, fixture_bytes, '\n');
    var case_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fixture = try std.json.parseFromSlice(std.json.Value, allocator, line, parse_options);
        defer fixture.deinit();

        try std.testing.expect(fixture.value == .object);
        const name = try expectFixtureString(fixture.value.object, "name");
        const expected = try expectFixtureString(fixture.value.object, "expected");
        const input = try expectOptionalFixtureInput(fixture.value.object);
        assertParsedJsonEquals(allocator, input, expected) catch |err| {
            std.debug.print("JSON repair fixture failed: {s}\n", .{name});
            return err;
        };
        case_count += 1;
    }
    try std.testing.expect(case_count >= 12);
}

test "parseJsonWithRepair escapes invalid complete JSON string escapes" {
    const allocator = std.testing.allocator;
    var parsed = try parseJsonWithRepair(allocator, "{\"text\":\"Hello \\_Kimi\"}");
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualStrings("Hello \\_Kimi", parsed.value.object.get("text").?.string);
}

test "parseStreamingJson enforces deterministic input size limit" {
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(u8, JSON_REPAIR_MAX_INPUT_BYTES + 1);
    defer allocator.free(input);
    @memset(input, ' ');

    try assertParsedJsonEquals(allocator, input, "{}");
}

test "parseStreamingJson enforces deterministic nesting depth limit" {
    const allocator = std.testing.allocator;
    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);

    try input.appendNTimes(allocator, '[', JSON_REPAIR_MAX_NESTING_DEPTH + 1);
    try input.append(allocator, '0');

    try assertParsedJsonEquals(allocator, input.items, "{}");
}

test "parseStreamingJson enforces nesting depth limit for complete valid input" {
    const allocator = std.testing.allocator;
    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);

    try input.appendNTimes(allocator, '[', JSON_REPAIR_MAX_NESTING_DEPTH + 1);
    try input.append(allocator, '0');
    try input.appendNTimes(allocator, ']', JSON_REPAIR_MAX_NESTING_DEPTH + 1);

    try std.testing.expect(input.items.len <= JSON_REPAIR_MAX_INPUT_BYTES);
    try assertParsedJsonEquals(allocator, input.items, "{}");
}

test "parseStreamingJson preserves complete valid input within nesting depth limit" {
    const allocator = std.testing.allocator;
    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);

    try input.appendNTimes(allocator, '[', JSON_REPAIR_MAX_NESTING_DEPTH);
    try input.append(allocator, '0');
    try input.appendNTimes(allocator, ']', JSON_REPAIR_MAX_NESTING_DEPTH);

    try assertParsedJsonEquals(allocator, input.items, input.items);
}

test "parseStreamingJson enforces deterministic work limit" {
    const allocator = std.testing.allocator;
    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);

    try input.append(allocator, '[');
    const item_count = (JSON_REPAIR_MAX_WORK_UNITS / JSON_REPAIR_VALUE_WORK_UNITS) + 1;
    for (0..item_count) |index| {
        if (index > 0) try input.append(allocator, ',');
        try input.append(allocator, '0');
    }

    try std.testing.expect(input.items.len <= JSON_REPAIR_MAX_INPUT_BYTES);
    try assertParsedJsonEquals(allocator, input.items, "{}");
}

test "parseStreamingJson enforces work limit for complete valid input" {
    const allocator = std.testing.allocator;
    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);

    try input.append(allocator, '[');
    const item_count = (JSON_REPAIR_MAX_WORK_UNITS / JSON_REPAIR_VALUE_WORK_UNITS) + 1;
    for (0..item_count) |index| {
        if (index > 0) try input.append(allocator, ',');
        try input.append(allocator, '0');
    }
    try input.append(allocator, ']');

    try std.testing.expect(input.items.len <= JSON_REPAIR_MAX_INPUT_BYTES);
    try assertParsedJsonEquals(allocator, input.items, "{}");
}
