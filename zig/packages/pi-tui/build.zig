const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared_dep = b.dependency("pi_shared", .{
        .target = target,
        .optimize = optimize,
    });
    const shared_mod = shared_dep.module("shared");

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");

    const vaxis_widgets_dep = b.dependency("vaxis_widgets", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_widgets_mod = vaxis_widgets_dep.module("vaxis-widgets");

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "shared", .module = shared_mod },
        .{ .name = "vaxis", .module = vaxis_mod },
        .{ .name = "vaxis-widgets", .module = vaxis_widgets_mod },
    };

    const mod = b.addModule("tui", .{
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
    const test_step = b.step("test", "Run pi-tui unit tests");
    test_step.dependOn(&run_tests.step);

    _ = mod;
}
