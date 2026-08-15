const std = @import("std");

/// Returns true when the canonical (symlink-resolved) form of `path` is still
/// within `root`. Resolves `path` via `realPathFileAbsolute` so that
/// in-sandbox symlinks pointing outside the sandbox are rejected. When `path`
/// does not exist yet (e.g. a write target), the longest existing prefix is
/// resolved instead so that callers cannot write through an in-sandbox
/// symlinked directory that resolves outside the root. Returns true also
/// when no canonical form can be obtained (e.g. realpath unsupported on the
/// host); the caller is expected to have already performed the lexical
/// `isPathWithinSandbox` check.
pub fn isCanonicalPathWithinSandbox(
    io: std.Io,
    root: []const u8,
    path: []const u8,
) bool {
    if (root.len == 0) return false;
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_canonical = canonicalizeAbsolute(io, root, &root_buffer) orelse return true;

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var working = path;
    while (true) {
        if (canonicalizeAbsolute(io, working, &path_buffer)) |resolved| {
            return isPathWithinSandbox(root_canonical, resolved);
        }
        const parent = std.fs.path.dirname(working) orelse return true;
        if (parent.len == 0 or std.mem.eql(u8, parent, working)) return true;
        working = parent;
    }
}

fn canonicalizeAbsolute(io: std.Io, path: []const u8, buffer: []u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (!std.fs.path.isAbsolute(path)) return null;
    const n = std.Io.Dir.realPathFileAbsolute(io, path, buffer) catch return null;
    return buffer[0..n];
}

/// Returns true when `path` is within `root`, disallowing path traversal
/// via `..`, `.`, or empty components. Both paths must use the platform's
/// native path separator.
pub fn isPathWithinSandbox(root: []const u8, path: []const u8) bool {
    if (root.len == 0) return false;
    if (std.mem.eql(u8, root, path)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    const suffix_start = if (root[root.len - 1] == std.fs.path.sep)
        root.len
    else blk: {
        if (path.len <= root.len or path[root.len] != std.fs.path.sep) return false;
        break :blk root.len + 1;
    };
    return isSafeRelativePathSuffix(path[suffix_start..]);
}

fn isSafeRelativePathSuffix(suffix: []const u8) bool {
    var components = std.mem.splitScalar(u8, suffix, std.fs.path.sep);
    while (components.next()) |component| {
        if (component.len == 0) return false;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

test "isPathWithinSandbox accepts direct match and children" {
    try std.testing.expect(isPathWithinSandbox("/tmp/native-sandbox", "/tmp/native-sandbox"));
    try std.testing.expect(isPathWithinSandbox("/tmp/native-sandbox", "/tmp/native-sandbox/read.txt"));
    try std.testing.expect(isPathWithinSandbox("/tmp/native-sandbox/", "/tmp/native-sandbox/read.txt"));
}

test "isPathWithinSandbox rejects traversal and siblings" {
    try std.testing.expect(!isPathWithinSandbox("/tmp/native-sandbox", "/tmp/native-sandbox/../outside.txt"));
    try std.testing.expect(!isPathWithinSandbox("/tmp/native-sandbox", "/tmp/native-sandbox/sub/../../outside.txt"));
    try std.testing.expect(!isPathWithinSandbox("/tmp/native-sandbox", "/tmp/native-sandbox/./inside.txt"));
    try std.testing.expect(!isPathWithinSandbox("/tmp/native-sandbox", "/tmp/native-sandbox-sibling/read.txt"));
    try std.testing.expect(!isPathWithinSandbox("", "/tmp/native-sandbox/read.txt"));
}
