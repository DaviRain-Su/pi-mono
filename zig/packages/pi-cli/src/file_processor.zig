const std = @import("std");
const ai = @import("ai");
const input_prep = @import("input_prep.zig");

pub const ProcessedFiles = struct {
    text: []u8,
    images: []ai.ImageContent = &.{},

    pub fn deinit(self: *ProcessedFiles, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.images) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        if (self.images.len > 0) allocator.free(self.images);
        self.* = undefined;
    }
};

pub const ProcessFileOptions = struct {
    auto_resize_images: bool = true,
};

pub fn processFileArguments(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    file_args: []const []const u8,
    stderr: *std.Io.Writer,
    options: ProcessFileOptions,
) !ProcessedFiles {
    var prepared = try input_prep.prepareInitialInput(
        allocator,
        io,
        env_map,
        cwd,
        file_args,
        &.{},
        null,
        stderr,
        .{ .auto_resize_images = options.auto_resize_images },
    );
    defer prepared.deinit(allocator);

    const text = prepared.prompt orelse try allocator.alloc(u8, 0);
    prepared.prompt = null;

    const images = prepared.images;
    prepared.images = &.{};

    return .{
        .text = text,
        .images = images,
    };
}

test "processFileArguments wraps text files in file tags" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/a.txt",
        .data = "hello",
    });

    const cwd = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    defer allocator.free(cwd);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var processed = try processFileArguments(
        allocator,
        std.testing.io,
        &env_map,
        cwd,
        &.{"a.txt"},
        &stderr_capture.writer,
        .{},
    );
    defer processed.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, processed.text, "<file name=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, processed.text, "hello\n</file>") != null);
    try std.testing.expectEqual(@as(usize, 0), processed.images.len);
}
