const builtin = @import("builtin");
const std = @import("std");
const ai = @import("ai");

const SUPPORTED_IMAGE_MIME_TYPES = [_][]const u8{
    "image/png",
    "image/jpeg",
    "image/webp",
    "image/gif",
};
const MAX_CLIPBOARD_BYTES = 50 * 1024 * 1024;

pub const ClipboardImage = struct {
    bytes: []u8,
    mime_type: []u8,

    pub fn deinit(self: *ClipboardImage, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.mime_type);
        self.* = undefined;
    }
};

/// Three-state result for clipboard image reads. `unsupported` is distinct
/// from `none` so callers can surface a deterministic user-visible message
/// when the clipboard contains image data in a format pi cannot accept
/// (e.g. image/bmp from WSLg) and no in-process converter is available.
pub const ClipboardImageResult = union(enum) {
    none,
    unsupported,
    image: ClipboardImage,
};

pub const ClipboardImageReaderFn = *const fn (
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) anyerror!ClipboardImageResult;

pub var clipboard_image_reader_context: ?*anyopaque = null;
pub var clipboard_image_reader_fn: ClipboardImageReaderFn = defaultReadClipboardImage;

pub fn readClipboardImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !ClipboardImageResult {
    return clipboard_image_reader_fn(clipboard_image_reader_context, allocator, io, env_map);
}

pub fn encodeImageContent(allocator: std.mem.Allocator, image: ClipboardImage) !ai.ImageContent {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(image.bytes.len));
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    return .{
        .data = encoded,
        .mime_type = try allocator.dupe(u8, image.mime_type),
    };
}

pub fn deinitImageContent(allocator: std.mem.Allocator, image: *ai.ImageContent) void {
    allocator.free(image.data);
    allocator.free(image.mime_type);
    image.* = undefined;
}

pub const CommandOutput = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    /// True when the underlying command runner could not start the binary
    /// (e.g. ENOENT). Tests stubs use this to model "command missing" so the
    /// platform fallback chain advances to the next reader.
    not_found: bool = false,

    pub fn releaseStdout(self: *CommandOutput) []u8 {
        const stdout = self.stdout;
        self.stdout = &.{};
        return stdout;
    }

    pub fn deinit(self: *CommandOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const ClipboardCommandRunnerFn = *const fn (
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argv: []const []const u8,
) anyerror!CommandOutput;

pub var clipboard_command_runner_context: ?*anyopaque = null;
pub var clipboard_command_runner_fn: ClipboardCommandRunnerFn = defaultRunCommand;

/// Optional override for the temporary file path used by the WSL PowerShell
/// fallback. Tests assign this so the deterministic write/read round-trip
/// happens in a fixture-controlled directory.
pub var clipboard_temp_file_override: ?[]const u8 = null;

fn defaultRunCommand(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argv: []const []const u8,
) !CommandOutput {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = env_map,
        .stdout_limit = .limited(MAX_CLIPBOARD_BYTES),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return CommandOutput{
            .stdout = &.{},
            .stderr = &.{},
            .exit_code = 127,
            .not_found = true,
        },
        else => return err,
    };
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exitCodeFromTerm(result.term),
    };
}

fn defaultReadClipboardImage(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !ClipboardImageResult {
    return switch (builtin.os.tag) {
        .macos => try readClipboardImageMacos(allocator, io, env_map),
        .windows => try readClipboardImageWindows(allocator, io, env_map),
        else => try readClipboardImageLinux(allocator, io, env_map),
    };
}

fn runCommandCapture(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argv: []const []const u8,
) !CommandOutput {
    return clipboard_command_runner_fn(clipboard_command_runner_context, allocator, io, env_map, argv);
}

fn exitCodeFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

fn readClipboardImageMacos(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !ClipboardImageResult {
    const script =
        \\import AppKit
        \\import Foundation
        \\let pb = NSPasteboard.general
        \\func write(_ data: Data) {
        \\    FileHandle.standardOutput.write(data)
        \\    exit(0)
        \\}
        \\if let png = pb.data(forType: .png) { write(png) }
        \\if let tiff = pb.data(forType: .tiff),
        \\   let rep = NSBitmapImageRep(data: tiff),
        \\   let png = rep.representation(using: .png, properties: [:]) {
        \\    write(png)
        \\}
        \\for type in pb.types ?? [] {
        \\    let raw = type.rawValue.lowercased()
        \\    if raw.contains("png"), let data = pb.data(forType: type) { write(data) }
        \\    if raw.contains("jpeg") || raw.contains("jpg"), let data = pb.data(forType: type) { write(data) }
        \\    if raw.contains("gif"), let data = pb.data(forType: type) { write(data) }
        \\    if raw.contains("webp"), let data = pb.data(forType: type) { write(data) }
        \\}
        \\exit(1)
    ;

    var output = try runCommandCapture(allocator, io, env_map, &[_][]const u8{ "swift", "-e", script });
    errdefer output.deinit(allocator);
    if (output.not_found or output.exit_code != 0 or output.stdout.len == 0) {
        output.deinit(allocator);
        return .none;
    }

    const detected = detectImageMime(output.stdout);
    const mime = detected orelse {
        // Unknown bytes from `swift` -> treat as unsupported so the user sees a
        // deterministic message rather than corrupt content.
        output.deinit(allocator);
        return .unsupported;
    };
    return .{ .image = .{
        .bytes = output.releaseStdout(),
        .mime_type = try allocator.dupe(u8, mime),
    } };
}

fn readClipboardImageWindows(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !ClipboardImageResult {
    const script =
        \\Add-Type -AssemblyName System.Windows.Forms
        \\Add-Type -AssemblyName System.Drawing
        \\$img = [System.Windows.Forms.Clipboard]::GetImage()
        \\if (-not $img) { exit 1 }
        \\$stream = New-Object System.IO.MemoryStream
        \\$img.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        \\$bytes = $stream.ToArray()
        \\[Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length)
    ;

    var output = try runCommandCapture(allocator, io, env_map, &[_][]const u8{
        "powershell.exe",
        "-NoProfile",
        "-Sta",
        "-Command",
        script,
    });
    errdefer output.deinit(allocator);
    if (output.not_found or output.exit_code != 0 or output.stdout.len == 0) {
        output.deinit(allocator);
        return .none;
    }

    return .{ .image = .{
        .bytes = output.releaseStdout(),
        .mime_type = try allocator.dupe(u8, "image/png"),
    } };
}

fn readClipboardImageLinux(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !ClipboardImageResult {
    const wayland = isWaylandSession(env_map);
    const wsl = isWslSession(env_map);

    var saw_unsupported = false;

    if (wayland or wsl) {
        const wl_result = try readClipboardImageViaWlPaste(allocator, io, env_map);
        switch (wl_result) {
            .image => return wl_result,
            .unsupported => saw_unsupported = true,
            .none => {},
        }

        const xclip_result = try readClipboardImageViaXclip(allocator, io, env_map);
        switch (xclip_result) {
            .image => return xclip_result,
            .unsupported => saw_unsupported = true,
            .none => {},
        }
    }

    if (wsl) {
        const ps_result = try readClipboardImageViaPowerShellWsl(allocator, io, env_map);
        switch (ps_result) {
            .image, .unsupported => return ps_result,
            .none => {},
        }
    }

    if (!wayland and !wsl) {
        // Plain X11 path: xclip is the canonical tool.
        const xclip_result = try readClipboardImageViaXclip(allocator, io, env_map);
        switch (xclip_result) {
            .image => return xclip_result,
            .unsupported => saw_unsupported = true,
            .none => {},
        }
    }

    if (saw_unsupported) return .unsupported;
    return .none;
}

fn isWaylandSession(env_map: *const std.process.Environ.Map) bool {
    if (env_map.get("WAYLAND_DISPLAY") != null) return true;
    const session_type = env_map.get("XDG_SESSION_TYPE") orelse return false;
    return std.ascii.eqlIgnoreCase(session_type, "wayland");
}

fn isWslSession(env_map: *const std.process.Environ.Map) bool {
    if (env_map.get("WSL_DISTRO_NAME") != null) return true;
    if (env_map.get("WSLENV") != null) return true;
    return false;
}

fn readClipboardImageViaWlPaste(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !ClipboardImageResult {
    var listed = try runCommandCapture(allocator, io, env_map, &[_][]const u8{ "wl-paste", "--list-types" });
    defer listed.deinit(allocator);
    if (listed.not_found or listed.exit_code != 0 or listed.stdout.len == 0) return .none;

    const supported = selectSupportedImageMimeTypeFromLines(listed.stdout);
    const has_unsupported_image = hasAnyImageMimeType(listed.stdout);

    if (supported == null) {
        if (has_unsupported_image) return .unsupported;
        return .none;
    }

    const selected = supported.?;
    var data = try runCommandCapture(allocator, io, env_map, &[_][]const u8{
        "wl-paste",
        "--type",
        selected,
        "--no-newline",
    });
    errdefer data.deinit(allocator);
    if (data.not_found or data.exit_code != 0 or data.stdout.len == 0) {
        data.deinit(allocator);
        return .none;
    }

    return .{ .image = .{
        .bytes = data.releaseStdout(),
        .mime_type = try allocator.dupe(u8, baseMimeType(selected)),
    } };
}

fn readClipboardImageViaXclip(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !ClipboardImageResult {
    var supported_selection: ?[]const u8 = null;
    var has_unsupported_image = false;
    var listed_targets: ?CommandOutput = null;

    var targets = runCommandCapture(allocator, io, env_map, &[_][]const u8{
        "xclip",
        "-selection",
        "clipboard",
        "-t",
        "TARGETS",
        "-o",
    }) catch |err| switch (err) {
        error.FileNotFound => return .none,
        else => return err,
    };
    if (targets.not_found) {
        targets.deinit(allocator);
        return .none;
    }
    listed_targets = targets;
    defer if (listed_targets) |*listed| listed.deinit(allocator);

    if (listed_targets.?.exit_code == 0 and listed_targets.?.stdout.len > 0) {
        supported_selection = selectSupportedImageMimeTypeFromLines(listed_targets.?.stdout);
        has_unsupported_image = hasAnyImageMimeType(listed_targets.?.stdout);
    }

    if (supported_selection) |mime_type| {
        if (try readClipboardImageViaXclipMime(allocator, io, env_map, mime_type)) |image| {
            return .{ .image = image };
        }
    }

    for (SUPPORTED_IMAGE_MIME_TYPES) |mime_type| {
        if (supported_selection) |already_selected| {
            if (std.mem.eql(u8, baseMimeType(already_selected), mime_type)) continue;
        }
        if (try readClipboardImageViaXclipMime(allocator, io, env_map, mime_type)) |image| {
            return .{ .image = image };
        }
    }

    if (has_unsupported_image and supported_selection == null) return .unsupported;
    return .none;
}

fn readClipboardImageViaXclipMime(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    mime_type: []const u8,
) !?ClipboardImage {
    var data = try runCommandCapture(allocator, io, env_map, &[_][]const u8{
        "xclip",
        "-selection",
        "clipboard",
        "-t",
        mime_type,
        "-o",
    });
    errdefer data.deinit(allocator);
    if (data.not_found or data.exit_code != 0 or data.stdout.len == 0) {
        data.deinit(allocator);
        return null;
    }

    return .{
        .bytes = data.releaseStdout(),
        .mime_type = try allocator.dupe(u8, baseMimeType(mime_type)),
    };
}

/// WSL-specific fallback: when neither wl-paste nor xclip have an image (the
/// usual case for Win+Shift+S screenshots that only land in the Windows
/// clipboard), shell out via `wslpath` + `powershell.exe` to write the
/// clipboard image as PNG into a temp file, then read the bytes back. The
/// temp file is removed even on failure paths.
fn readClipboardImageViaPowerShellWsl(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !ClipboardImageResult {
    const tmp_path = if (clipboard_temp_file_override) |override|
        try allocator.dupe(u8, override)
    else
        try generateWslTempFilePath(allocator, io);
    defer allocator.free(tmp_path);

    var winpath = runCommandCapture(allocator, io, env_map, &[_][]const u8{ "wslpath", "-w", tmp_path }) catch |err| switch (err) {
        error.FileNotFound => return .none,
        else => return err,
    };
    defer winpath.deinit(allocator);
    if (winpath.not_found or winpath.exit_code != 0 or winpath.stdout.len == 0) return .none;

    const win_path_trimmed = std.mem.trim(u8, winpath.stdout, " \t\r\n");
    if (win_path_trimmed.len == 0) return .none;

    // Escape single quotes for PowerShell single-quoted string literal.
    var ps_path = std.ArrayList(u8).empty;
    defer ps_path.deinit(allocator);
    for (win_path_trimmed) |c| {
        if (c == '\'') try ps_path.appendSlice(allocator, "''") else try ps_path.append(allocator, c);
    }

    const script = try std.fmt.allocPrint(
        allocator,
        "Add-Type -AssemblyName System.Windows.Forms; " ++
            "Add-Type -AssemblyName System.Drawing; " ++
            "$path = '{s}'; " ++
            "$img = [System.Windows.Forms.Clipboard]::GetImage(); " ++
            "if ($img) {{ $img.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); Write-Output 'ok' }} else {{ Write-Output 'empty' }}",
        .{ps_path.items},
    );
    defer allocator.free(script);

    var ps = runCommandCapture(allocator, io, env_map, &[_][]const u8{
        "powershell.exe",
        "-NoProfile",
        "-Command",
        script,
    }) catch |err| {
        // Best-effort cleanup.
        std.Io.Dir.deleteFile(.cwd(), io, tmp_path) catch {};
        return err;
    };
    defer ps.deinit(allocator);

    // Always remove the temp file (whether the read succeeds or not).
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp_path) catch {};

    if (ps.not_found or ps.exit_code != 0) return .none;
    const trimmed = std.mem.trim(u8, ps.stdout, " \t\r\n");
    if (!std.mem.eql(u8, trimmed, "ok")) return .none;

    const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, tmp_path, allocator, .limited(MAX_CLIPBOARD_BYTES)) catch return .none;
    if (bytes.len == 0) {
        allocator.free(bytes);
        return .none;
    }

    return .{ .image = .{
        .bytes = bytes,
        .mime_type = try allocator.dupe(u8, "image/png"),
    } };
}

var wsl_temp_file_counter = std.atomic.Value(u64).init(0);

fn generateWslTempFilePath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const counter = wsl_temp_file_counter.fetchAdd(1, .seq_cst);
    const now_ns: i128 = std.Io.Clock.now(.awake, io).nanoseconds;
    const seed: u64 = @as(u64, @bitCast(@as(i64, @truncate(now_ns)))) ^ counter;
    return try std.fmt.allocPrint(allocator, "/tmp/pi-wsl-clip-{x}.png", .{seed});
}

fn baseMimeType(mime_type: []const u8) []const u8 {
    const separator = std.mem.indexOfScalar(u8, mime_type, ';') orelse mime_type.len;
    return std.mem.trim(u8, mime_type[0..separator], " \t\r\n");
}

/// Return the first line whose base MIME matches one of
/// SUPPORTED_IMAGE_MIME_TYPES, in declaration order (png, jpeg, webp, gif).
/// Returns null if no supported image MIME is present.
fn selectSupportedImageMimeTypeFromLines(text: []const u8) ?[]const u8 {
    for (SUPPORTED_IMAGE_MIME_TYPES) |preferred| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0) continue;
            if (std.mem.eql(u8, baseMimeType(line), preferred)) return line;
        }
    }
    return null;
}

/// Convenience for the original behaviour (supported first, then any
/// `image/*`). Kept for places that previously fell back to unsupported
/// MIMEs (no remaining production caller; retained for backwards-compatible
/// tests).
fn selectPreferredImageMimeTypeFromLines(text: []const u8) ?[]const u8 {
    if (selectSupportedImageMimeTypeFromLines(text)) |selected| return selected;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, baseMimeType(line), "image/")) return line;
    }
    return null;
}

fn hasAnyImageMimeType(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, baseMimeType(line), "image/")) return true;
    }
    return false;
}

fn detectImageMime(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return "image/jpeg";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) {
        return "image/gif";
    }
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        return "image/webp";
    }
    return null;
}

test "selectSupportedImageMimeTypeFromLines prefers supported formats and strips parameters" {
    const selected = selectSupportedImageMimeTypeFromLines(
        \\image/bmp
        \\image/png;charset=utf-8
        \\image/jpeg
    ) orelse return error.ExpectedMimeType;

    try std.testing.expectEqualStrings("image/png;charset=utf-8", selected);
    try std.testing.expectEqualStrings("image/png", baseMimeType(selected));
}

test "selectSupportedImageMimeTypeFromLines follows declared preference order regardless of source order" {
    const selected = selectSupportedImageMimeTypeFromLines(
        \\image/gif
        \\image/jpeg
        \\image/webp
        \\image/png
    ) orelse return error.ExpectedMimeType;

    try std.testing.expectEqualStrings("image/png", selected);
}

test "selectSupportedImageMimeTypeFromLines returns null when only unsupported image MIMEs are present" {
    const selected = selectSupportedImageMimeTypeFromLines(
        \\image/bmp
        \\image/tiff
    );
    try std.testing.expectEqual(@as(?[]const u8, null), selected);
}

test "hasAnyImageMimeType detects unsupported image entries" {
    try std.testing.expect(hasAnyImageMimeType("image/bmp\n"));
    try std.testing.expect(!hasAnyImageMimeType("text/plain\nUTF8_STRING\n"));
}

test "encodeImageContent base64 encodes clipboard bytes" {
    const allocator = std.testing.allocator;

    var image = ClipboardImage{
        .bytes = try allocator.dupe(u8, &[_]u8{ 0x01, 0x02, 0x03 }),
        .mime_type = try allocator.dupe(u8, "image/png"),
    };
    defer image.deinit(allocator);

    var encoded = try encodeImageContent(allocator, image);
    defer deinitImageContent(allocator, &encoded);

    try std.testing.expectEqualStrings("AQID", encoded.data);
    try std.testing.expectEqualStrings("image/png", encoded.mime_type);
}

// =============================================================================
// VAL-M14 deterministic clipboard tests
// =============================================================================

fn tmpDirAbsolutePath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, ".zig-cache", "tmp", &tmp.sub_path, name });
}

const ClipboardCommandStub = struct {
    pub const Response = struct {
        argv_match: []const []const u8,
        stdout: []const u8 = "",
        stderr: []const u8 = "",
        exit_code: u8 = 0,
        not_found: bool = false,
    };

    pub const Invocation = struct {
        argv: [][]const u8,

        fn deinit(self: *Invocation, allocator: std.mem.Allocator) void {
            for (self.argv) |arg| allocator.free(arg);
            allocator.free(self.argv);
        }
    };

    allocator: std.mem.Allocator,
    responses: []const Response,
    invocations: std.ArrayList(Invocation) = .empty,

    pub fn init(allocator: std.mem.Allocator, responses: []const Response) ClipboardCommandStub {
        return .{ .allocator = allocator, .responses = responses };
    }

    pub fn deinit(self: *ClipboardCommandStub) void {
        for (self.invocations.items) |*inv| inv.deinit(self.allocator);
        self.invocations.deinit(self.allocator);
    }

    pub fn install(self: *ClipboardCommandStub) struct {
        prev_ctx: ?*anyopaque,
        prev_fn: ClipboardCommandRunnerFn,
    } {
        const prev_ctx = clipboard_command_runner_context;
        const prev_fn = clipboard_command_runner_fn;
        clipboard_command_runner_context = @ptrCast(self);
        clipboard_command_runner_fn = run;
        return .{ .prev_ctx = prev_ctx, .prev_fn = prev_fn };
    }

    pub fn restore(prev: anytype) void {
        clipboard_command_runner_context = prev.prev_ctx;
        clipboard_command_runner_fn = prev.prev_fn;
    }

    fn matches(stub_argv: []const []const u8, actual_argv: []const []const u8) bool {
        if (stub_argv.len == 0) return true;
        if (stub_argv.len > actual_argv.len) return false;
        for (stub_argv, actual_argv[0..stub_argv.len]) |expected, actual| {
            if (!std.mem.eql(u8, expected, actual)) return false;
        }
        return true;
    }

    fn run(
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        argv: []const []const u8,
    ) !CommandOutput {
        _ = io;
        _ = env_map;
        const self: *ClipboardCommandStub = @ptrCast(@alignCast(ctx orelse return error.MissingStub));

        // Record invocation.
        var argv_copy = try self.allocator.alloc([]const u8, argv.len);
        for (argv, 0..) |arg, i| argv_copy[i] = try self.allocator.dupe(u8, arg);
        try self.invocations.append(self.allocator, .{ .argv = argv_copy });

        for (self.responses) |resp| {
            if (!matches(resp.argv_match, argv)) continue;
            return CommandOutput{
                .stdout = try allocator.dupe(u8, resp.stdout),
                .stderr = try allocator.dupe(u8, resp.stderr),
                .exit_code = resp.exit_code,
                .not_found = resp.not_found,
            };
        }
        // Default: command not found.
        return CommandOutput{
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, ""),
            .exit_code = 127,
            .not_found = true,
        };
    }
};

fn invocationCommand(inv: ClipboardCommandStub.Invocation) []const u8 {
    return inv.argv[0];
}

test "VAL-M14-IMAGE-001 wl-paste selects preferred MIME order from clipboard targets" {
    const allocator = std.testing.allocator;

    const png_bytes = "\x89PNG\r\n\x1a\nrest";
    const responses = [_]ClipboardCommandStub.Response{
        .{
            .argv_match = &.{ "wl-paste", "--list-types" },
            .stdout = "image/bmp\nimage/jpeg\nimage/png\nimage/webp\n",
        },
        .{
            .argv_match = &.{ "wl-paste", "--type", "image/png", "--no-newline" },
            .stdout = png_bytes,
        },
    };
    var stub = ClipboardCommandStub.init(allocator, &responses);
    defer stub.deinit();
    const prev = stub.install();
    defer ClipboardCommandStub.restore(prev);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("WAYLAND_DISPLAY", "wayland-0");

    const result = try readClipboardImageLinux(allocator, std.testing.io, &env_map);
    try std.testing.expect(result == .image);
    var image = result.image;
    defer image.deinit(allocator);

    try std.testing.expectEqualStrings("image/png", image.mime_type);
    try std.testing.expectEqualSlices(u8, png_bytes, image.bytes);

    // Two invocations: list types + read png. No xclip / powershell were tried.
    try std.testing.expectEqual(@as(usize, 2), stub.invocations.items.len);
    try std.testing.expectEqualStrings("wl-paste", invocationCommand(stub.invocations.items[0]));
    try std.testing.expectEqualStrings("wl-paste", invocationCommand(stub.invocations.items[1]));
    try std.testing.expectEqualStrings("image/png", stub.invocations.items[1].argv[2]);
}

test "VAL-M14-IMAGE-002 unsupported clipboard MIME results in unsupported sentinel" {
    const allocator = std.testing.allocator;

    const responses = [_]ClipboardCommandStub.Response{
        .{
            .argv_match = &.{ "wl-paste", "--list-types" },
            .stdout = "image/bmp\nimage/tiff\n",
        },
        // xclip not available -> falls back to PowerShell (also not available).
        .{ .argv_match = &.{"xclip"}, .not_found = true, .exit_code = 127 },
        .{ .argv_match = &.{"wslpath"}, .not_found = true, .exit_code = 127 },
        .{ .argv_match = &.{"powershell.exe"}, .not_found = true, .exit_code = 127 },
    };
    var stub = ClipboardCommandStub.init(allocator, &responses);
    defer stub.deinit();
    const prev = stub.install();
    defer ClipboardCommandStub.restore(prev);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("WAYLAND_DISPLAY", "wayland-0");

    const result = try readClipboardImageLinux(allocator, std.testing.io, &env_map);
    try std.testing.expect(result == .unsupported);

    // No `wl-paste --type ...` call should have been made because no supported MIME was offered.
    var saw_type_read = false;
    for (stub.invocations.items) |inv| {
        if (std.mem.eql(u8, invocationCommand(inv), "wl-paste") and inv.argv.len >= 2 and std.mem.eql(u8, inv.argv[1], "--type")) {
            saw_type_read = true;
        }
    }
    try std.testing.expect(!saw_type_read);
}

test "VAL-M14-IMAGE-003 platform fallback order: wl-paste then xclip then wsl powershell" {
    const allocator = std.testing.allocator;

    // Use a deterministic temp file so the WSL PowerShell branch reads the bytes
    // we wrote, instead of generating a random path.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmpDirAbsolutePath(allocator, tmp_dir, "fallback.png");
    defer allocator.free(tmp_path);

    const png_bytes_array = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x44, 0x45, 0x46 };
    const png_bytes: []const u8 = png_bytes_array[0..];

    // Pre-write the file the way `powershell.exe ... $img.Save(...)` would.
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = tmp_path, .data = png_bytes });

    const previous_override = clipboard_temp_file_override;
    clipboard_temp_file_override = tmp_path;
    defer clipboard_temp_file_override = previous_override;

    const responses = [_]ClipboardCommandStub.Response{
        // wl-paste returns no image at all -> next reader.
        .{ .argv_match = &.{ "wl-paste", "--list-types" }, .stdout = "text/plain\nUTF8_STRING\n" },
        // xclip TARGETS also returns no image -> next reader.
        .{
            .argv_match = &.{ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" },
            .stdout = "TARGETS\nTIMESTAMP\n",
        },
        // SUPPORTED MIME probe attempts each return zero bytes.
        .{ .argv_match = &.{"xclip"}, .stdout = "", .exit_code = 1 },
        // WSL fallback chain.
        .{ .argv_match = &.{ "wslpath", "-w" }, .stdout = "C:\\Users\\fallback.png\n" },
        .{ .argv_match = &.{"powershell.exe"}, .stdout = "ok\n" },
    };
    var stub = ClipboardCommandStub.init(allocator, &responses);
    defer stub.deinit();
    const prev = stub.install();
    defer ClipboardCommandStub.restore(prev);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("WAYLAND_DISPLAY", "wayland-0");
    try env_map.put("WSL_DISTRO_NAME", "Ubuntu");

    const result = try readClipboardImageLinux(allocator, std.testing.io, &env_map);
    try std.testing.expect(result == .image);
    var image = result.image;
    defer image.deinit(allocator);

    try std.testing.expectEqualStrings("image/png", image.mime_type);
    try std.testing.expectEqualSlices(u8, png_bytes, image.bytes);

    // Verify command order: wl-paste --list-types, xclip TARGETS, xclip type
    // probes, wslpath, powershell.exe. The fallback does NOT short-circuit
    // before the WSL branch.
    try std.testing.expect(stub.invocations.items.len >= 4);
    try std.testing.expectEqualStrings("wl-paste", invocationCommand(stub.invocations.items[0]));
    try std.testing.expectEqualStrings("xclip", invocationCommand(stub.invocations.items[1]));
    var saw_wslpath = false;
    var saw_powershell = false;
    for (stub.invocations.items) |inv| {
        if (std.mem.eql(u8, invocationCommand(inv), "wslpath")) saw_wslpath = true;
        if (std.mem.eql(u8, invocationCommand(inv), "powershell.exe")) saw_powershell = true;
    }
    try std.testing.expect(saw_wslpath);
    try std.testing.expect(saw_powershell);

    // Verify temp file was deleted by the WSL reader.
    const stat_after = std.Io.Dir.statFile(.cwd(), std.testing.io, tmp_path, .{});
    try std.testing.expectError(error.FileNotFound, stat_after);
}

test "VAL-M14-IMAGE-003 wl-paste short-circuits before xclip and powershell" {
    const allocator = std.testing.allocator;

    const png_bytes = "\x89PNG\r\n\x1a\nshortcut";
    const responses = [_]ClipboardCommandStub.Response{
        .{ .argv_match = &.{ "wl-paste", "--list-types" }, .stdout = "image/png\n" },
        .{ .argv_match = &.{ "wl-paste", "--type", "image/png", "--no-newline" }, .stdout = png_bytes },
    };
    var stub = ClipboardCommandStub.init(allocator, &responses);
    defer stub.deinit();
    const prev = stub.install();
    defer ClipboardCommandStub.restore(prev);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("WAYLAND_DISPLAY", "wayland-0");
    try env_map.put("WSL_DISTRO_NAME", "Ubuntu");

    const result = try readClipboardImageLinux(allocator, std.testing.io, &env_map);
    try std.testing.expect(result == .image);
    var image = result.image;
    defer image.deinit(allocator);

    for (stub.invocations.items) |inv| {
        try std.testing.expect(!std.mem.eql(u8, invocationCommand(inv), "xclip"));
        try std.testing.expect(!std.mem.eql(u8, invocationCommand(inv), "powershell.exe"));
        try std.testing.expect(!std.mem.eql(u8, invocationCommand(inv), "wslpath"));
    }
}

test "VAL-M14-IMAGE-004 WSL PowerShell fallback writes/reads temp file path round trip" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmpDirAbsolutePath(allocator, tmp_dir, "wsl-paste.png");
    defer allocator.free(tmp_path);

    const png_bytes_array = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 'b', 'o', 'd', 'y' };
    const png_bytes: []const u8 = png_bytes_array[0..];

    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = tmp_path, .data = png_bytes });

    const previous_override = clipboard_temp_file_override;
    clipboard_temp_file_override = tmp_path;
    defer clipboard_temp_file_override = previous_override;

    const responses = [_]ClipboardCommandStub.Response{
        .{ .argv_match = &.{"wslpath"}, .stdout = "C:\\Users\\test\\img.png\n" },
        .{ .argv_match = &.{"powershell.exe"}, .stdout = "ok\n" },
    };
    var stub = ClipboardCommandStub.init(allocator, &responses);
    defer stub.deinit();
    const prev = stub.install();
    defer ClipboardCommandStub.restore(prev);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const result = try readClipboardImageViaPowerShellWsl(allocator, std.testing.io, &env_map);
    try std.testing.expect(result == .image);
    var image = result.image;
    defer image.deinit(allocator);

    try std.testing.expectEqualStrings("image/png", image.mime_type);
    try std.testing.expectEqualSlices(u8, png_bytes, image.bytes);

    // Temp file must be gone after the read (no dependency on source path).
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(.cwd(), std.testing.io, tmp_path, .{}));

    // PowerShell argv must contain the wslpath-translated Windows path.
    var saw_powershell_with_path = false;
    for (stub.invocations.items) |inv| {
        if (!std.mem.eql(u8, invocationCommand(inv), "powershell.exe")) continue;
        for (inv.argv) |arg| {
            if (std.mem.indexOf(u8, arg, "C:\\\\Users\\\\test\\\\img.png") != null or
                std.mem.indexOf(u8, arg, "C:\\Users\\test\\img.png") != null)
            {
                saw_powershell_with_path = true;
            }
        }
    }
    try std.testing.expect(saw_powershell_with_path);
}

test "VAL-M14-IMAGE-004 WSL PowerShell fallback escapes single quotes in path" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmpDirAbsolutePath(allocator, tmp_dir, "wsl-paste-quote.png");
    defer allocator.free(tmp_path);

    const png_bytes = "\x89PNG\r\n\x1a\nQUOTE";
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = tmp_path, .data = png_bytes });

    const previous_override = clipboard_temp_file_override;
    clipboard_temp_file_override = tmp_path;
    defer clipboard_temp_file_override = previous_override;

    const responses = [_]ClipboardCommandStub.Response{
        .{ .argv_match = &.{"wslpath"}, .stdout = "C:\\Users\\O'Hare\\clip.png\n" },
        .{ .argv_match = &.{"powershell.exe"}, .stdout = "ok\n" },
    };
    var stub = ClipboardCommandStub.init(allocator, &responses);
    defer stub.deinit();
    const prev = stub.install();
    defer ClipboardCommandStub.restore(prev);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const result = try readClipboardImageViaPowerShellWsl(allocator, std.testing.io, &env_map);
    try std.testing.expect(result == .image);
    var image = result.image;
    defer image.deinit(allocator);

    var saw_escaped = false;
    for (stub.invocations.items) |inv| {
        if (!std.mem.eql(u8, invocationCommand(inv), "powershell.exe")) continue;
        for (inv.argv) |arg| {
            if (std.mem.indexOf(u8, arg, "$path = 'C:\\Users\\O''Hare\\clip.png'") != null) {
                saw_escaped = true;
            }
        }
    }
    try std.testing.expect(saw_escaped);
}
