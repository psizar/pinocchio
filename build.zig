const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "pinocchio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.linkFramework("Hypervisor");

    const install = b.addInstallArtifact(exe, .{});

    const sign = b.addSystemCommand(&.{
        "codesign",
        "--entitlements",
        "entitlements.plist",
        "--force",
        "-s",
        "-",
    });
    sign.addArtifactArg(exe);

    sign.step.dependOn(&install.step);

    b.getInstallStep().dependOn(&sign.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&sign.step);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
