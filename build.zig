const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const entitlements = "entitlements.plist";
    const hv_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/hv.h"),
        .target = target,
        .optimize = optimize,
    });

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "hyper",
                .module = hv_translate.createModule(),
            },
        },
    });

    root.linkFramework("Hypervisor", .{});

    const exe = b.addExecutable(.{
        .name = "vmmd",
        .root_module = root,
    });
    exe.entitlements = entitlements;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = root,
    });
    tests.entitlements = entitlements;

    const test_cmd = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_cmd.step);
}
