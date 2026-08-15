const std = @import("std");
const builtin = @import("builtin");
const ai = @import("ai");
const config = @import("../config/config.zig");

const http_client = ai.http_client;

const NETWORK_TIMEOUT_MS: u32 = 10_000;
const DOWNLOAD_TIMEOUT_MS: u32 = 120_000;

pub const Tool = enum {
    fd,
    rg,

    pub fn binaryName(self: Tool) []const u8 {
        return switch (self) {
            .fd => "fd",
            .rg => "rg",
        };
    }

    pub fn displayName(self: Tool) []const u8 {
        return switch (self) {
            .fd => "fd",
            .rg => "ripgrep",
        };
    }

    pub fn repo(self: Tool) []const u8 {
        return switch (self) {
            .fd => "sharkdp/fd",
            .rg => "BurntSushi/ripgrep",
        };
    }

    pub fn tagPrefix(self: Tool) []const u8 {
        return switch (self) {
            .fd => "v",
            .rg => "",
        };
    }
};

pub const Platform = enum {
    darwin,
    linux,
    win32,
    android,
    unsupported,
};

pub const Architecture = enum {
    x64,
    arm64,
    unsupported,
};

pub fn isOfflineModeEnabled(env_map: *const std.process.Environ.Map) bool {
    const value = env_map.get("PI_OFFLINE") orelse return false;
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

pub fn getBinDir(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    const agent_dir = try config.resolveAgentDir(allocator, env_map);
    defer allocator.free(agent_dir);
    return std.fs.path.join(allocator, &.{ agent_dir, "bin" });
}

pub fn getToolPath(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, tool: Tool) !?[]u8 {
    const bin_dir = try getBinDir(allocator, env_map);
    defer allocator.free(bin_dir);

    const binary_file_name = try binaryFileName(allocator, tool);
    defer allocator.free(binary_file_name);

    const local_path = try std.fs.path.join(allocator, &.{ bin_dir, binary_file_name });
    errdefer allocator.free(local_path);
    if (fileExists(io, local_path)) return local_path;
    allocator.free(local_path);

    for (systemBinaryNames(tool)) |name| {
        if (commandExists(allocator, io, name)) return try allocator.dupe(u8, name);
    }

    return null;
}

pub fn ensureTool(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, tool: Tool) !?[]u8 {
    if (try getToolPath(allocator, io, env_map, tool)) |path| return path;
    if (isOfflineModeEnabled(env_map)) return null;
    if (detectPlatform(env_map) == .android) return null;
    return downloadTool(allocator, io, env_map, tool) catch null;
}

pub fn getAssetName(allocator: std.mem.Allocator, tool: Tool, version: []const u8, platform: Platform, architecture: Architecture) !?[]u8 {
    const arch_text = switch (architecture) {
        .arm64 => "aarch64",
        .x64 => "x86_64",
        .unsupported => return null,
    };

    return switch (tool) {
        .fd => switch (platform) {
            .darwin => try std.fmt.allocPrint(allocator, "fd-v{s}-{s}-apple-darwin.tar.gz", .{ version, arch_text }),
            .linux => try std.fmt.allocPrint(allocator, "fd-v{s}-{s}-unknown-linux-gnu.tar.gz", .{ version, arch_text }),
            .win32 => try std.fmt.allocPrint(allocator, "fd-v{s}-{s}-pc-windows-msvc.zip", .{ version, arch_text }),
            else => null,
        },
        .rg => switch (platform) {
            .darwin => try std.fmt.allocPrint(allocator, "ripgrep-{s}-{s}-apple-darwin.tar.gz", .{ version, arch_text }),
            .linux => if (architecture == .arm64)
                try std.fmt.allocPrint(allocator, "ripgrep-{s}-aarch64-unknown-linux-gnu.tar.gz", .{version})
            else
                try std.fmt.allocPrint(allocator, "ripgrep-{s}-x86_64-unknown-linux-musl.tar.gz", .{version}),
            .win32 => try std.fmt.allocPrint(allocator, "ripgrep-{s}-{s}-pc-windows-msvc.zip", .{ version, arch_text }),
            else => null,
        },
    };
}

fn downloadTool(allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, tool: Tool) ![]u8 {
    const platform = detectPlatform(env_map);
    const architecture = detectArchitecture();
    const version = try getLatestVersion(allocator, io, tool.repo());
    defer allocator.free(version);

    const asset_name = (try getAssetName(allocator, tool, version, platform, architecture)) orelse return error.UnsupportedPlatform;
    defer allocator.free(asset_name);

    const bin_dir = try getBinDir(allocator, env_map);
    defer allocator.free(bin_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, bin_dir);

    const download_url = try std.fmt.allocPrint(
        allocator,
        "https://github.com/{s}/releases/download/{s}{s}/{s}",
        .{ tool.repo(), tool.tagPrefix(), version, asset_name },
    );
    defer allocator.free(download_url);

    const archive_path = try std.fs.path.join(allocator, &.{ bin_dir, asset_name });
    defer allocator.free(archive_path);

    const binary_file_name = try binaryFileName(allocator, tool);
    defer allocator.free(binary_file_name);

    const binary_path = try std.fs.path.join(allocator, &.{ bin_dir, binary_file_name });
    errdefer allocator.free(binary_path);

    try downloadFile(allocator, io, download_url, archive_path);

    const extract_dir_name = try std.fmt.allocPrint(
        allocator,
        "extract_tmp_{s}_{d}_{d}",
        .{ tool.binaryName(), std.process.getpid(), std.Io.Clock.now(.wall, io).nanoseconds },
    );
    defer allocator.free(extract_dir_name);

    const extract_dir = try std.fs.path.join(allocator, &.{ bin_dir, extract_dir_name });
    defer allocator.free(extract_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, extract_dir);

    defer {
        std.Io.Dir.deleteFile(.cwd(), io, archive_path) catch {};
        std.Io.Dir.deleteTree(.cwd(), io, extract_dir) catch {};
    }

    try extractArchive(allocator, io, asset_name, archive_path, extract_dir);

    const extracted_binary = try findBinaryRecursively(allocator, io, extract_dir, binary_file_name) orelse return error.BinaryNotFound;
    defer allocator.free(extracted_binary);
    try renameReplace(io, extracted_binary, binary_path);
    if (platform != .win32) std.posix.chmod(binary_path, 0o755) catch {};

    return binary_path;
}

fn getLatestVersion(allocator: std.mem.Allocator, io: std.Io, repo: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/releases/latest", .{repo});
    defer allocator.free(url);

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("User-Agent", "pi-coding-agent");

    var client = try http_client.HttpClient.init(allocator, io);
    defer client.deinit();
    const response = try client.request(.{
        .method = .GET,
        .url = url,
        .headers = headers,
        .timeout_ms = NETWORK_TIMEOUT_MS,
        .max_response_body_bytes = 1024 * 1024,
    });
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const tag_name = if (parsed.value == .object) blk: {
        const value = parsed.value.object.get("tag_name") orelse return error.InvalidReleaseResponse;
        if (value != .string) return error.InvalidReleaseResponse;
        break :blk value.string;
    } else return error.InvalidReleaseResponse;

    return allocator.dupe(u8, if (std.mem.startsWith(u8, tag_name, "v")) tag_name[1..] else tag_name);
}

fn downloadFile(allocator: std.mem.Allocator, io: std.Io, url: []const u8, destination: []const u8) !void {
    var client = try http_client.HttpClient.init(allocator, io);
    defer client.deinit();
    const response = try client.request(.{
        .method = .GET,
        .url = url,
        .timeout_ms = DOWNLOAD_TIMEOUT_MS,
        .max_response_body_bytes = 512 * 1024 * 1024,
    });
    defer response.deinit();
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = destination, .data = response.body });
}

fn extractArchive(allocator: std.mem.Allocator, io: std.Io, asset_name: []const u8, archive_path: []const u8, extract_dir: []const u8) !void {
    const argv = if (std.mem.endsWith(u8, asset_name, ".tar.gz"))
        &[_][]const u8{ "tar", "xzf", archive_path, "-C", extract_dir }
    else if (std.mem.endsWith(u8, asset_name, ".zip"))
        &[_][]const u8{ "unzip", "-q", archive_path, "-d", extract_dir }
    else
        return error.UnsupportedArchiveFormat;

    const result = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (exitCodeFromTerm(result.term) != 0) return error.ExtractFailed;
}

fn findBinaryRecursively(allocator: std.mem.Allocator, io: std.Io, root_dir: []const u8, binary_file_name: []const u8) !?[]u8 {
    var stack: std.ArrayList([]u8) = .empty;
    defer {
        for (stack.items) |item| allocator.free(item);
        stack.deinit(allocator);
    }
    try stack.append(allocator, try allocator.dupe(u8, root_dir));

    while (stack.pop()) |current_dir| {
        defer allocator.free(current_dir);
        var dir = std.Io.Dir.openDirAbsolute(io, current_dir, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            const full_path = try std.fs.path.join(allocator, &.{ current_dir, entry.name });
            errdefer allocator.free(full_path);
            switch (entry.kind) {
                .file => {
                    if (std.mem.eql(u8, entry.name, binary_file_name)) return full_path;
                    allocator.free(full_path);
                },
                .directory => try stack.append(allocator, full_path),
                else => allocator.free(full_path),
            }
        }
    }

    return null;
}

fn renameReplace(io: std.Io, source: []const u8, destination: []const u8) !void {
    std.Io.Dir.deleteFile(.cwd(), io, destination) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return std.fs.renameAbsolute(source, destination);
}

fn commandExists(allocator: std.mem.Allocator, io: std.Io, command: []const u8) bool {
    const result = std.process.run(allocator, io, .{ .argv = &[_][]const u8{ command, "--version" } }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term == .exited;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch return false;
    return true;
}

fn binaryFileName(allocator: std.mem.Allocator, tool: Tool) ![]u8 {
    if (builtin.os.tag == .windows) return std.fmt.allocPrint(allocator, "{s}.exe", .{tool.binaryName()});
    return allocator.dupe(u8, tool.binaryName());
}

fn systemBinaryNames(tool: Tool) []const []const u8 {
    return switch (tool) {
        .fd => &.{ "fd", "fdfind" },
        .rg => &.{"rg"},
    };
}

fn detectPlatform(env_map: *const std.process.Environ.Map) Platform {
    if (env_map.get("TERMUX_VERSION") != null) return .android;
    return switch (builtin.os.tag) {
        .macos => .darwin,
        .linux => .linux,
        .windows => .win32,
        else => .unsupported,
    };
}

fn detectArchitecture() Architecture {
    return switch (builtin.cpu.arch) {
        .aarch64 => .arm64,
        .x86_64 => .x64,
        else => .unsupported,
    };
}

fn exitCodeFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

fn makeTmpPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir, sub_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, sub_path });
}

test "tools manager detects offline mode" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    try std.testing.expect(!isOfflineModeEnabled(&env_map));
    try env_map.put("PI_OFFLINE", "yes");
    try std.testing.expect(isOfflineModeEnabled(&env_map));
}

test "tools manager maps release asset names" {
    const allocator = std.testing.allocator;
    const fd = (try getAssetName(allocator, .fd, "10.2.0", .darwin, .arm64)).?;
    defer allocator.free(fd);
    try std.testing.expectEqualStrings("fd-v10.2.0-aarch64-apple-darwin.tar.gz", fd);

    const rg = (try getAssetName(allocator, .rg, "14.1.1", .linux, .x64)).?;
    defer allocator.free(rg);
    try std.testing.expectEqualStrings("ripgrep-14.1.1-x86_64-unknown-linux-musl.tar.gz", rg);
}

test "tools manager prefers managed binary path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent/bin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/bin/fd", .data = "fixture" });

    const agent_dir = try makeTmpPath(allocator, &tmp, "agent");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    const found = (try getToolPath(allocator, std.testing.io, &env_map, .fd)).?;
    defer allocator.free(found);
    try std.testing.expect(std.mem.endsWith(u8, found, "agent/bin/fd"));
}
