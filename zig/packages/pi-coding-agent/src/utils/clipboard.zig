const std = @import("std");
const builtin = @import("builtin");

pub const MAX_OSC52_ENCODED_LENGTH: usize = 100_000;

pub const CopyResult = union(enum) {
    native,
    osc52: []u8,

    pub fn deinit(self: *CopyResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .osc52 => |value| allocator.free(value),
            .native => {},
        }
        self.* = undefined;
    }
};

pub fn isRemoteSession(env_map: *const std.process.Environ.Map) bool {
    return env_map.get("SSH_CONNECTION") != null or
        env_map.get("SSH_CLIENT") != null or
        env_map.get("MOSH_CONNECTION") != null;
}

pub fn buildOsc52Sequence(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(text.len);
    if (encoded_len > MAX_OSC52_ENCODED_LENGTH) return null;

    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, text);
    return try std.fmt.allocPrint(allocator, "\x1b]52;c;{s}\x07", .{encoded});
}

pub fn copyToClipboard(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    text: []const u8,
) !CopyResult {
    const remote = isRemoteSession(env_map);
    var copied = false;

    if (!copied) copied = tryCopyNative(io, env_map, text);
    if (copied and !remote) return .native;

    if (try buildOsc52Sequence(allocator, text)) |sequence| {
        return .{ .osc52 = sequence };
    }

    if (copied) return .native;
    return error.FailedToCopyToClipboard;
}

fn tryCopyNative(io: std.Io, env_map: *const std.process.Environ.Map, text: []const u8) bool {
    switch (builtin.os.tag) {
        .macos => return runClipboardCommand(io, &.{"pbcopy"}, text),
        .windows => return runClipboardCommand(io, &.{"clip"}, text),
        else => {
            if (env_map.get("TERMUX_VERSION") != null and runClipboardCommand(io, &.{"termux-clipboard-set"}, text)) return true;
            if (env_map.get("WAYLAND_DISPLAY") != null and runClipboardCommand(io, &.{"wl-copy"}, text)) return true;
            if (env_map.get("DISPLAY") != null) {
                if (runClipboardCommand(io, &.{ "xclip", "-selection", "clipboard" }, text)) return true;
                if (runClipboardCommand(io, &.{ "xsel", "--clipboard", "--input" }, text)) return true;
            }
            return false;
        },
    }
}

pub fn runClipboardCommand(io: std.Io, argv: []const []const u8, text: []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    defer {
        if (child.id != null) child.kill(io);
    }

    const stdin_file = child.stdin orelse return false;
    child.stdin = null;

    var buffer: [1024]u8 = undefined;
    var writer = stdin_file.writer(io, &buffer);
    writer.interface.writeAll(text) catch return false;
    writer.flush() catch return false;
    stdin_file.close(io);

    const term = child.wait(io) catch return false;
    return exitCodeFromChildTerm(term) == 0;
}

fn exitCodeFromChildTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

test "clipboard detects remote sessions" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try std.testing.expect(!isRemoteSession(&env_map));
    try env_map.put("SSH_CONNECTION", "host");
    try std.testing.expect(isRemoteSession(&env_map));
}

test "clipboard builds OSC52 sequence" {
    const sequence = (try buildOsc52Sequence(std.testing.allocator, "hello")).?;
    defer std.testing.allocator.free(sequence);
    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x07", sequence);
}

test "clipboard rejects oversized OSC52 payloads" {
    const data = try std.testing.allocator.alloc(u8, MAX_OSC52_ENCODED_LENGTH);
    defer std.testing.allocator.free(data);
    @memset(data, 'a');
    try std.testing.expectEqual(null, try buildOsc52Sequence(std.testing.allocator, data));
}
