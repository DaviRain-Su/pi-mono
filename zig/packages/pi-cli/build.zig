const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const coding_dep = b.dependency("pi_coding_agent", .{
        .target = target,
        .optimize = optimize,
    });
    const agent_dep = b.dependency("pi_agent_core", .{
        .target = target,
        .optimize = optimize,
    });
    const ai_dep = b.dependency("pi_ai", .{
        .target = target,
        .optimize = optimize,
    });
    const shared_dep = b.dependency("pi_shared", .{
        .target = target,
        .optimize = optimize,
    });

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "coding_agent", .module = coding_dep.module("coding_agent") },
        .{ .name = "agent", .module = agent_dep.module("agent") },
        .{ .name = "ai", .module = ai_dep.module("ai") },
        .{ .name = "shared", .module = shared_dep.module("shared") },
    };

    const mod = b.addModule("cli", .{
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
    const test_step = b.step("test", "Run pi-cli unit tests");
    test_step.dependOn(&run_tests.step);

    _ = mod;
}
