const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const types_dep = b.dependency("pi_types", .{
        .target = target,
        .optimize = optimize,
    });
    const types_mod = types_dep.module("pi-types");

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "pi-types", .module = types_mod },
    };

    const mod = b.addModule("ai", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = imports,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run pi-ai unit tests");
    test_step.dependOn(&run_tests.step);

    _ = mod;
}
