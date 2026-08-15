const std = @import("std");
const image_convert = @import("image_convert.zig");
const image_resize = @import("image_resize.zig");

pub const WASM_FILENAME = "photon_rs_bg.wasm";

pub const PhotonBackend = struct {
    name: []const u8 = "zigimg",
    supports_decode: bool = true,
    supports_png_encode: bool = true,
    supports_jpeg_encode: bool = true,
    supports_resize: bool = true,
};

pub fn loadPhoton() ?PhotonBackend {
    return .{};
}

pub fn getFallbackWasmPaths(allocator: std.mem.Allocator, exec_dir: []const u8, cwd: []const u8) ![]const []u8 {
    var paths = try allocator.alloc([]u8, 3);
    errdefer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }
    paths[0] = try std.fs.path.join(allocator, &.{ exec_dir, WASM_FILENAME });
    paths[1] = try std.fs.path.join(allocator, &.{ exec_dir, "photon", WASM_FILENAME });
    paths[2] = try std.fs.path.join(allocator, &.{ cwd, WASM_FILENAME });
    return paths;
}

pub fn freeFallbackWasmPaths(allocator: std.mem.Allocator, paths: []const []u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

pub const convertToPng = image_convert.convertToPng;
pub const resizeImage = image_resize.resizeImage;

test "photon compatibility loader exposes zigimg backend" {
    const backend = loadPhoton().?;
    try std.testing.expectEqualStrings("zigimg", backend.name);
    try std.testing.expect(backend.supports_resize);
}

test "photon fallback wasm paths match TypeScript search order" {
    const paths = try getFallbackWasmPaths(std.testing.allocator, "/bin", "/cwd");
    defer freeFallbackWasmPaths(std.testing.allocator, paths);
    try std.testing.expectEqualStrings("/bin/photon_rs_bg.wasm", paths[0]);
    try std.testing.expectEqualStrings("/bin/photon/photon_rs_bg.wasm", paths[1]);
    try std.testing.expectEqualStrings("/cwd/photon_rs_bg.wasm", paths[2]);
}
