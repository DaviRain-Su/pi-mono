const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const types_dep = b.dependency("pi_types", .{
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
    const tui_dep = b.dependency("pi_tui", .{
        .target = target,
        .optimize = optimize,
    });
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "pi-types", .module = types_dep.module("pi-types") },
        .{ .name = "agent", .module = agent_dep.module("agent") },
        .{ .name = "ai", .module = ai_dep.module("ai") },
        .{ .name = "shared", .module = shared_dep.module("shared") },
        .{ .name = "tui", .module = tui_dep.module("tui") },
        .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
    };

    const mod = b.addModule("coding_agent", .{
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
    run_tests.setCwd(b.path("../.."));
    const test_step = b.step("test", "Run pi-coding-agent unit tests");
    test_step.dependOn(&run_tests.step);

    _ = mod;
}
