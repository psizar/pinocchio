const std = @import("std");
const Io = std.Io;

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

    const int_tests_cmd = b.step("test-integration", "Run Integration Tests");

    const int_tests_step = b.allocator.create(IntegrationTestStep) catch @panic("OOM");
    int_tests_step.* = IntegrationTestStep{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = "integration-test",
            .owner = b,
            .makeFn = makeIntegrationTest,
        }),
        .exe = exe,
    };

    int_tests_step.step.dependOn(&exe.step);
    int_tests_cmd.dependOn(&int_tests_step.step);
}

const IntegrationTestStep = struct {
    step: std.Build.Step,
    exe: *std.Build.Step.Compile,
};

fn makeIntegrationTest(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;

    const self: *IntegrationTestStep = @fieldParentPtr("step", step);

    const gpa = step.owner.allocator;
    const io = step.owner.graph.io;
    const server_path = self.exe.generated_bin.?.getPath();

    var child = try std.process.spawn(io, .{
        .argv = &.{server_path},
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    defer child.kill(io);

    var mr_buf: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();

    const stdout_r = mr.reader(0);
    const stderr_r = mr.reader(1);

    const init_str = "Hello from Pinocchio Guest (PID 1)!";
    var found = false;
    var term: enum { deadline_hit, eos, fill_err } = .deadline_hit;

    const start = Io.Clock.awake.now(io);
    const timeout_s: i64 = 60;
    const deadline = start.addDuration(Io.Duration.fromSeconds(timeout_s));
    const deadline_ts: Io.Clock.Timestamp = .{ .raw = deadline, .clock = .awake };

    while (true) {
        if (Io.Clock.awake.now(io).nanoseconds >= deadline.nanoseconds) break;

        mr.fill(8192, .{ .deadline = deadline_ts }) catch |err| switch (err) {
            error.Timeout => break,
            error.EndOfStream => {
                term = .eos;
                if (std.mem.find(u8, stdout_r.buffered(), init_str) != null or
                    std.mem.find(u8, stderr_r.buffered(), init_str) != null) found = true;
                break;
            },
            else => {
                term = .fill_err;
                break;
            },
        };

        if (std.mem.find(u8, stdout_r.buffered(), init_str) != null or
            std.mem.find(u8, stderr_r.buffered(), init_str) != null)
        {
            found = true;
            break;
        }
    }

    const out_dir = step.owner.install_path;
    _ = try step.installDir(out_dir);
    {
        const stdout_path = step.owner.pathJoin(&.{ out_dir, "integration-stdout.log" });
        if (mr.toOwnedSlice(0)) |data| {
            defer gpa.free(data);
            _ = try Io.Dir.cwd().writeFile(io, .{ .sub_path = stdout_path, .data = data });
        } else |_| {}
    }

    {
        const stderr_path = step.owner.pathJoin(&.{ out_dir, "integration-stderr.log" });
        if (mr.toOwnedSlice(1)) |data| {
            defer gpa.free(data);
            _ = try Io.Dir.cwd().writeFile(io, .{ .sub_path = stderr_path, .data = data });
        } else |_| {}
    }

    if (found) return;

    try mr.checkAnyError();

    const msg = switch (term) {
        .deadline_hit => step.owner.fmt("timed out after {d}s waiting for init string", .{timeout_s}),
        .eos => "child exited before producing init string",
        .fill_err => "reader error (see zig-out/integration-stderr.log)",
    };

    return step.fail("{s}", .{msg});
}
