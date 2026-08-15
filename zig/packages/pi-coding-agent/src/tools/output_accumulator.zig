const std = @import("std");
const truncate = @import("truncate.zig");

var temp_file_counter: usize = 0;

pub const OutputAccumulatorOptions = struct {
    max_lines: usize = truncate.DEFAULT_MAX_LINES,
    max_bytes: usize = truncate.DEFAULT_MAX_BYTES,
    temp_file_prefix: []const u8 = "pi-output",
};

pub const OutputSnapshot = struct {
    content: []const u8,
    truncation: truncate.TruncationResult,
    full_output_path: ?[]const u8 = null,

    pub fn deinit(self: *OutputSnapshot, allocator: std.mem.Allocator) void {
        self.truncation.deinit(allocator);
        if (self.full_output_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub const OutputAccumulator = struct {
    allocator: std.mem.Allocator,
    options: OutputAccumulatorOptions,
    buffer: std.ArrayList(u8),
    total_lines: usize = 1,
    current_line_bytes: usize = 0,
    finished: bool = false,
    temp_file_path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, options: OutputAccumulatorOptions) OutputAccumulator {
        return .{
            .allocator = allocator,
            .options = options,
            .buffer = .empty,
        };
    }

    pub fn deinit(self: *OutputAccumulator) void {
        self.buffer.deinit(self.allocator);
        if (self.temp_file_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn append(self: *OutputAccumulator, data: []const u8) !void {
        if (self.finished) return error.OutputAccumulatorFinished;
        try self.buffer.appendSlice(self.allocator, data);
        self.updateCounters(data);
    }

    pub fn finish(self: *OutputAccumulator) void {
        self.finished = true;
    }

    pub fn snapshot(self: *OutputAccumulator, persist_if_truncated: bool) !OutputSnapshot {
        var result = try truncate.truncateTail(self.allocator, self.buffer.items, .{
            .max_lines = self.options.max_lines,
            .max_bytes = self.options.max_bytes,
        });
        result.truncated = result.truncated or self.total_lines > self.options.max_lines or self.buffer.items.len > self.options.max_bytes;
        result.total_lines = self.total_lines;
        result.total_bytes = self.buffer.items.len;

        if (persist_if_truncated and result.truncated) try self.ensureTempFile();
        return .{
            .content = result.content,
            .truncation = result,
            .full_output_path = if (self.temp_file_path) |path| try self.allocator.dupe(u8, path) else null,
        };
    }

    pub fn getLastLineBytes(self: *const OutputAccumulator) usize {
        return self.current_line_bytes;
    }

    fn updateCounters(self: *OutputAccumulator, data: []const u8) void {
        var last_newline_index: ?usize = null;
        for (data, 0..) |byte, index| {
            if (byte == '\n') {
                self.total_lines += 1;
                last_newline_index = index;
            }
        }
        if (last_newline_index) |index| {
            self.current_line_bytes = data.len - index - 1;
        } else {
            self.current_line_bytes += data.len;
        }
    }

    fn ensureTempFile(self: *OutputAccumulator) !void {
        if (self.temp_file_path != null) return;
        temp_file_counter += 1;
        const path = try std.fmt.allocPrint(self.allocator, "/tmp/{s}-{d}.log", .{
            self.options.temp_file_prefix,
            temp_file_counter,
        });
        errdefer self.allocator.free(path);
        const io = std.Io.Threaded.global_single_threaded.io();
        var file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
        defer file.close(io);
        var file_buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &file_buffer);
        try writer.interface.writeAll(self.buffer.items);
        try writer.interface.flush();
        self.temp_file_path = path;
    }
};

test "output accumulator snapshots tail and persists truncated output" {
    const allocator = std.testing.allocator;
    var accumulator = OutputAccumulator.init(allocator, .{ .max_lines = 2, .max_bytes = 64, .temp_file_prefix = "pi-output-test" });
    defer accumulator.deinit();

    try accumulator.append("one\ntwo\nthree");
    var snapshot = try accumulator.snapshot(true);
    defer snapshot.deinit(allocator);

    try std.testing.expect(snapshot.truncation.truncated);
    try std.testing.expectEqualStrings("two\nthree", snapshot.content);
    try std.testing.expect(snapshot.full_output_path != null);
}
