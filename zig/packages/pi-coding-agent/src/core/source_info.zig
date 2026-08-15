const std = @import("std");

pub const SourceScope = enum {
    user,
    project,
    temporary,
};

pub const SourceOrigin = enum {
    package,
    top_level,
};

pub const SourceProvenanceBinding = struct {
    lock_entry_key: []const u8,
    source_identity: []const u8,
    package_root: []const u8,
    package_root_sha256: []const u8,
    artifact_sha256: ?[]const u8 = null,
};

pub const PathMetadata = struct {
    source: []const u8,
    scope: SourceScope,
    origin: SourceOrigin,
    base_dir: ?[]const u8 = null,
    provenance: ?SourceProvenanceBinding = null,
};

pub const SourceInfo = struct {
    path: []const u8,
    source: []const u8,
    scope: SourceScope,
    origin: SourceOrigin,
    base_dir: ?[]const u8 = null,
    provenance: ?SourceProvenanceBinding = null,
};

pub const SyntheticSourceInfoOptions = struct {
    source: []const u8,
    scope: SourceScope = .temporary,
    origin: SourceOrigin = .top_level,
    base_dir: ?[]const u8 = null,
};

pub fn createSourceInfo(path: []const u8, metadata: PathMetadata) SourceInfo {
    return .{
        .path = path,
        .source = metadata.source,
        .scope = metadata.scope,
        .origin = metadata.origin,
        .base_dir = metadata.base_dir,
        .provenance = metadata.provenance,
    };
}

pub fn createSyntheticSourceInfo(path: []const u8, options: SyntheticSourceInfoOptions) SourceInfo {
    return .{
        .path = path,
        .source = options.source,
        .scope = options.scope,
        .origin = options.origin,
        .base_dir = options.base_dir,
    };
}

test "createSyntheticSourceInfo defaults to temporary top-level source" {
    const info = createSyntheticSourceInfo("skills/foo", .{ .source = "test" });
    try std.testing.expectEqual(SourceScope.temporary, info.scope);
    try std.testing.expectEqual(SourceOrigin.top_level, info.origin);
}
