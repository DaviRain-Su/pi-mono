const std = @import("std");
const ai = @import("ai");
const cli = @import("args.zig");
const config_mod = @import("coding_agent").config_impl;
const file_image = @import("coding_agent").file_image;

pub const CliStdin = struct {
    is_tty: bool = true,
    content: ?[]const u8 = null,
    owns_content: bool = false,

    pub fn deinit(self: *CliStdin, allocator: std.mem.Allocator) void {
        if (self.owns_content and self.content != null) allocator.free(self.content.?);
        self.* = .{};
    }
};

pub const PreparedInitialInput = struct {
    prompt: ?[]u8 = null,
    messages: []const []const u8 = &.{},
    images: []ai.ImageContent = &.{},

    pub fn deinit(self: *PreparedInitialInput, allocator: std.mem.Allocator) void {
        if (self.prompt) |prompt| allocator.free(prompt);
        if (self.images.len > 0) {
            for (self.images) |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            }
            allocator.free(self.images);
        }
        self.* = .{};
    }
};

pub fn stdinIsTty(io: std.Io) bool {
    return std.Io.File.stdin().isTty(io) catch true;
}

pub fn detectCliStdin(allocator: std.mem.Allocator, io: std.Io, mode: cli.Mode) !CliStdin {
    if (mode == .rpc or mode == .ts_rpc or stdinIsTty(io)) return .{};

    const content = try readPipedStdin(allocator, io);
    return .{
        .is_tty = false,
        .content = content,
        .owns_content = content != null,
    };
}

fn readPipedStdin(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var collected = std.ArrayList(u8).empty;
    defer collected.deinit(allocator);

    while (true) {
        const byte = stdin_reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try collected.append(allocator, byte);
    }

    const trimmed = std.mem.trim(u8, collected.items, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

pub const PrepareInitialInputOptions = struct {
    /// When true (the TS default) file image attachments are routed through
    /// the deterministic file_image processor, which can omit them with a
    /// dimension note or omission message. When false, supported images are
    /// inserted with their original bytes (matches TS `autoResizeImages =
    /// false`).
    auto_resize_images: bool = true,
};

pub fn prepareInitialInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    file_args: ?[]const []const u8,
    messages: []const []const u8,
    stdin_content: ?[]const u8,
    stderr: *std.Io.Writer,
    options: PrepareInitialInputOptions,
) !PreparedInitialInput {
    var file_text = std.ArrayList(u8).empty;
    defer file_text.deinit(allocator);
    var images = std.ArrayList(ai.ImageContent).empty;
    errdefer {
        for (images.items) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        images.deinit(allocator);
    }

    if (file_args) |paths| {
        for (paths) |path| {
            const absolute_path = try config_mod.expandPath(allocator, env_map, path, cwd);
            defer allocator.free(absolute_path);

            const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, absolute_path, allocator, .unlimited) catch |err| {
                switch (err) {
                    error.FileNotFound => try stderr.print("Error: File not found: {s}\n", .{absolute_path}),
                    else => try stderr.print("Error: Could not read file {s}: {s}\n", .{ absolute_path, @errorName(err) }),
                }
                return error.CliInputFailed;
            };
            defer allocator.free(bytes);

            if (bytes.len == 0) continue;

            if (file_image.detectImageMime(bytes)) |mime_type| {
                try appendFileImage(
                    allocator,
                    &file_text,
                    &images,
                    absolute_path,
                    bytes,
                    mime_type,
                    options.auto_resize_images,
                );
            } else {
                const header = try std.fmt.allocPrint(allocator, "<file name=\"{s}\">\n", .{absolute_path});
                defer allocator.free(header);
                try file_text.appendSlice(allocator, header);
                try file_text.appendSlice(allocator, bytes);
                try file_text.appendSlice(allocator, "\n</file>\n");
            }
        }
    }

    var prompt_builder = std.ArrayList(u8).empty;
    defer prompt_builder.deinit(allocator);
    if (stdin_content) |content| try prompt_builder.appendSlice(allocator, content);
    if (file_text.items.len > 0) try prompt_builder.appendSlice(allocator, file_text.items);
    if (messages.len > 0) try prompt_builder.appendSlice(allocator, messages[0]);

    return .{
        .prompt = if (prompt_builder.items.len > 0)
            try prompt_builder.toOwnedSlice(allocator)
        else
            null,
        .messages = if (messages.len > 1) messages[1..] else &.{},
        .images = try images.toOwnedSlice(allocator),
    };
}

/// Append a single file image attachment + its `<file>` text reference,
/// honoring the auto-resize gate, the deterministic file_image processor,
/// the dimension-note emission, and the omission message. Mirrors the TS
/// `processFileArguments` image branch byte-for-byte.
fn appendFileImage(
    allocator: std.mem.Allocator,
    file_text: *std.ArrayList(u8),
    images: *std.ArrayList(ai.ImageContent),
    absolute_path: []const u8,
    bytes: []const u8,
    mime_type: []const u8,
    auto_resize_images: bool,
) !void {
    if (!auto_resize_images) {
        // TS path with autoResizeImages=false: insert original bytes verbatim
        // and emit an empty `<file>` reference.
        const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
        errdefer allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, bytes);
        try images.append(allocator, .{
            .data = encoded,
            .mime_type = try allocator.dupe(u8, mime_type),
        });
        const note = try std.fmt.allocPrint(allocator, "<file name=\"{s}\"></file>\n", .{absolute_path});
        defer allocator.free(note);
        try file_text.appendSlice(allocator, note);
        return;
    }

    const result = try file_image.processImage(allocator, .{
        .bytes = bytes,
        .mime_type = mime_type,
        .options = .{},
    });
    if (result == null) {
        // TS: `text += `<file name="${absolutePath}">[Image omitted: could not be resized below the inline image size limit.]</file>\n`;`
        const omission = try std.fmt.allocPrint(
            allocator,
            "<file name=\"{s}\">{s}</file>\n",
            .{ absolute_path, file_image.OMISSION_MESSAGE },
        );
        defer allocator.free(omission);
        try file_text.appendSlice(allocator, omission);
        return;
    }

    var processed = result.?;
    // Take ownership of the processor-allocated buffers and hand them to the
    // images list directly to avoid an extra copy.
    const data_b64 = processed.data_b64;
    const processed_mime = processed.mime_type;
    processed.data_b64 = &.{};
    processed.mime_type = &.{};
    try images.append(allocator, .{
        .data = data_b64,
        .mime_type = processed_mime,
    });

    if (try file_image.formatDimensionNote(allocator, processed)) |dim_note| {
        defer allocator.free(dim_note);
        const wrapped = try std.fmt.allocPrint(
            allocator,
            "<file name=\"{s}\">{s}</file>\n",
            .{ absolute_path, dim_note },
        );
        defer allocator.free(wrapped);
        try file_text.appendSlice(allocator, wrapped);
    } else {
        const note = try std.fmt.allocPrint(allocator, "<file name=\"{s}\"></file>\n", .{absolute_path});
        defer allocator.free(note);
        try file_text.appendSlice(allocator, note);
    }
}

test "prepareInitialInput keeps follow-up positional messages separate" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var prepared = try prepareInitialInput(
        allocator,
        std.testing.io,
        &env_map,
        "/tmp/project",
        null,
        &.{ "first prompt", "second prompt", "third prompt" },
        null,
        &stderr_capture.writer,
        .{},
    );
    defer prepared.deinit(allocator);

    try std.testing.expectEqualStrings("first prompt", prepared.prompt.?);
    try std.testing.expectEqual(@as(usize, 2), prepared.messages.len);
    try std.testing.expectEqualStrings("second prompt", prepared.messages[0]);
    try std.testing.expectEqualStrings("third prompt", prepared.messages[1]);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}
