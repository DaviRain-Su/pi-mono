const std = @import("std");

pub const PromptTemplate = struct {
    name: []const u8,
    description: []const u8,
    argument_hint: ?[]const u8 = null,
    content: []const u8,
    file_path: []const u8,
};

pub fn parseCommandArgs(allocator: std.mem.Allocator, args_string: []const u8) ![][]u8 {
    var args: std.ArrayList([]u8) = .empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var quote: ?u8 = null;
    for (args_string) |ch| {
        if (quote) |q| {
            if (ch == q) {
                quote = null;
            } else {
                try current.append(allocator, ch);
            }
        } else if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (std.ascii.isWhitespace(ch)) {
            // Mirror TS fix(coding-agent) #4553: split on any whitespace.
            if (current.items.len > 0) {
                try args.append(allocator, try current.toOwnedSlice(allocator));
                current.clearRetainingCapacity();
            }
        } else {
            try current.append(allocator, ch);
        }
    }
    if (current.items.len > 0) try args.append(allocator, try current.toOwnedSlice(allocator));
    return args.toOwnedSlice(allocator);
}

pub const freeCommandArgs = @import("../slice_utils.zig").freeStringSlice;

pub fn substituteArgs(allocator: std.mem.Allocator, content: []const u8, args: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] != '$') {
            try out.writer.writeByte(content[i]);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, content[i..], "$ARGUMENTS")) {
            try writeJoinedArgs(&out.writer, args, 0, args.len);
            i += "$ARGUMENTS".len;
            continue;
        }
        if (std.mem.startsWith(u8, content[i..], "$@")) {
            try writeJoinedArgs(&out.writer, args, 0, args.len);
            i += 2;
            continue;
        }
        if (i + 1 < content.len and std.ascii.isDigit(content[i + 1])) {
            var end = i + 1;
            while (end < content.len and std.ascii.isDigit(content[end])) : (end += 1) {}
            const index = (std.fmt.parseInt(usize, content[i + 1 .. end], 10) catch 0);
            if (index > 0 and index <= args.len) try out.writer.writeAll(args[index - 1]);
            i = end;
            continue;
        }
        try out.writer.writeByte(content[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

fn writeJoinedArgs(writer: *std.Io.Writer, args: []const []const u8, start: usize, end: usize) !void {
    for (args[start..end], 0..) |arg, index| {
        if (index > 0) try writer.writeByte(' ');
        try writer.writeAll(arg);
    }
}

test "prompt template args parse quotes and substitute positional values" {
    const allocator = std.testing.allocator;
    const args = try parseCommandArgs(allocator, "one \"two words\"");
    defer freeCommandArgs(allocator, args);
    try std.testing.expectEqual(@as(usize, 2), args.len);
    const rendered = try substituteArgs(allocator, "$1 $2 $@", args);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("one two words one two words", rendered);
}
