const std = @import("std");
const pi_types = @import("pi-types");

const prefer_strict: pi_types.ConstrainedSamplingConfig = .{ .json_schema = .{ .strict = .prefer } };

pub fn areExperimentalFeaturesEnabled() bool {
    const value = std.c.getenv("PI_EXPERIMENTAL") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1");
}

pub fn getExperimentalToolSampling() ?pi_types.ConstrainedSamplingConfig {
    return if (areExperimentalFeaturesEnabled()) prefer_strict else null;
}

fn experimentalToolUsesStrictSampling(name: []const u8) bool {
    return std.mem.eql(u8, name, "bash") or
        std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "edit") or
        std.mem.eql(u8, name, "write");
}

pub fn constrainedSamplingForBuiltin(name: []const u8) ?pi_types.ConstrainedSamplingConfig {
    return constrainedSamplingForBuiltinWithFlag(name, areExperimentalFeaturesEnabled());
}

pub fn constrainedSamplingForBuiltinWithFlag(
    name: []const u8,
    enabled: bool,
) ?pi_types.ConstrainedSamplingConfig {
    if (!enabled or !experimentalToolUsesStrictSampling(name)) return null;
    return prefer_strict;
}

test "constrainedSamplingForBuiltinWithFlag matches TS experimental tools" {
    const bash = constrainedSamplingForBuiltinWithFlag("bash", true) orelse return error.MissingSampling;
    try std.testing.expect(bash == .json_schema);
    try std.testing.expectEqual(pi_types.ConstrainedSamplingStrict.prefer, bash.json_schema.strict);
    try std.testing.expect(constrainedSamplingForBuiltinWithFlag("read", true) != null);
    try std.testing.expect(constrainedSamplingForBuiltinWithFlag("edit", true) != null);
    try std.testing.expect(constrainedSamplingForBuiltinWithFlag("write", true) != null);
    try std.testing.expect(constrainedSamplingForBuiltinWithFlag("grep", true) == null);
    try std.testing.expect(constrainedSamplingForBuiltinWithFlag("bash", false) == null);
}
