const std = @import("std");

pub fn main() !void {
    // Mount proc and sys
    _ = std.os.linux.mount("proc", "/proc", "proc", 0, 0);
    _ = std.os.linux.mount("sysfs", "/sys", "sysfs", 0, 0);

    const msg = "Hello from Pinocchio Guest (PID 1)!\n";
    _ = std.os.linux.write(1, msg, msg.len);

    const path: [*:0]const u8 = "/bin/busybox";
    const argv = [_:null]?[*:0]const u8{"/bin/sh"};
    const envp = [_:null]?[*:0]const u8{};
    _ = std.os.linux.execve(path, &argv, &envp);
}
