const hv = @cImport(
    @cInclude("Hypervisor/Hypervisor.h"),
);
const std = @import("std");
const posix = std.posix;

pub fn main() !void {
    const cr_stat = hv.hv_vm_create(null);
    defer _ = hv.hv_vm_destroy();

    if (cr_stat != 0) {
        @panic("failed to create VM");
    }

    const guest_mem_size = 128 * 1024 * 1024;

    const buffer = try posix.mmap(
        null,
        guest_mem_size,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer posix.munmap(buffer);

    // loadProgram(buffer, &program_m2);
    // loadProgram(buffer, &program_m3);
    // loadProgram(buffer, &program_m4);

    const kernel_offset = 0x200000; // 2MiB offset
    const dtb_offset = 0x0; // DTB at base of RAM

    // 1. Load DTB at the start of memory (0x40000000 in guest physical)
    const dtb_size = try loadFile(buffer[dtb_offset..], "guest/pinocchio.dtb");
    std.debug.print("Loaded DTB: {d} bytes\n", .{dtb_size});

    // 2. Load Kernel at 2MB offset (0x40200000 in guest physical)
    const kernel_size = try loadFile(buffer[kernel_offset..], "guest/vmlinuz");
    std.debug.print("Loaded kernel: {d} bytes\n", .{kernel_size});

    // 3. Map the entire 128MB into guest physical memory at 0x40000000
    const map_ret = hv.hv_vm_map(buffer.ptr, 0x40000000, guest_mem_size, hv.HV_MEMORY_READ | hv.HV_MEMORY_WRITE | hv.HV_MEMORY_EXEC);
    std.debug.print("map returned: 0x{x}\n", .{@as(u32, @bitCast(map_ret))});

    // execute(handler_m2);
    // execute(handler_m3);
    execute(kernel_handler);
}

fn loadFile(buffer: []u8, path: []const u8) !usize {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return try file.readAll(buffer);
}

fn loadProgram(buffer: []u8, prog: []const u32) void {
    for (prog, 0..) |item, i| {
        const start = i * 4;
        std.mem.writeInt(u32, buffer[start..][0..4], item, .little);
    }
}

fn execute(func: fn (vcpu: hv.hv_vcpu_t, exit: ?*hv.hv_vcpu_exit_t) void) void {
    var vcpu: hv.hv_vcpu_t = undefined;
    var exit: ?*hv.hv_vcpu_exit_t = undefined;

    _ = hv.hv_vcpu_create(&vcpu, &exit, null);
    defer _ = hv.hv_vcpu_destroy(vcpu);

    _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_X0, 0x40000000); // Address of DTB
    _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_PC, 0x40200000); // Kernel entry point
    _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_CPSR, 0x3C4); // set exception level to EL1

    func(vcpu, exit);
}

const program_m2 = [_]u32{
    0xd2800000, // mov x0, #0
    0xd28000a1, // mov x1, #5
    0xd4000002, // hvc #0
    0x91000400, // add x0, x0, #1
    0xeb01001f, // cmp x0, x1
    0x54ffffab, // b.lt -3
    0xd2800022, // mov x2, #1
    0xd4000002, // hvc #0
};

fn handler_m2(vcpu: hv.hv_vcpu_t, exit: ?*hv.hv_vcpu_exit_t) void {
    while (true) {
        const stat = hv.hv_vcpu_run(vcpu);
        if (stat != hv.HV_SUCCESS) {
            std.debug.print("failed continuation of code. status: {d}", .{@as(u32, @bitCast(stat))});
        }

        if (exit.?.reason != hv.HV_EXIT_REASON_EXCEPTION) {
            std.debug.print("exit reason not equal to HVC interrupt. Reason: {d}", .{exit.?.reason});
            break;
        }

        var counter: u64 = undefined;
        _ = hv.hv_vcpu_get_reg(vcpu, hv.HV_REG_X0, &counter);
        std.debug.print("Counter value: {d}\n", .{counter});

        var done: u64 = undefined;
        _ = hv.hv_vcpu_get_reg(vcpu, hv.HV_REG_X2, &done);

        if (done == 1) {
            std.debug.print("Loop completed\n", .{});
            return;
        }
    }
}

const program_m3 = [_]u32{
    0xd2a00023, // mov x3, #0x10000
    0x10000144, // adr x4, #40
    0xd2800165, // mov x5, #11
    0xd2800006, // mov x6, #0
    0x38666880, // ldrb w0, [x4, x6]
    0xf9000060, // str x0, [x3] -> trap to vmm
    0x910004c6, // add x6, x6, #1
    0xeb0500df, // cmp x6, x5
    0x54ffff8b, // b.lt -4
    0xd2800022, // mov x2, #1
    0xd4000002, // hvc #0

    // "Hello VMM!\n" as raw bytes
    0x6c6c6548, // ldnp d8, d25, [x10, #-0x140]
    0x4d56206f, // .long 0x4d56206f
    0x000a214d, // 0x6e0a214d
};

fn handler_m3(vcpu: hv.hv_vcpu_t, exit: ?*hv.hv_vcpu_exit_t) void {
    while (true) {
        _ = hv.hv_vcpu_run(vcpu);

        switch (exit.?.reason) {
            hv.HV_EXIT_REASON_EXCEPTION => {
                const syndrome = exit.?.exception.syndrome;
                switch (syndrome >> 26) {
                    0x16 => {
                        var done: u64 = undefined;
                        _ = hv.hv_vcpu_get_reg(vcpu, hv.HV_REG_X2, &done);

                        if (done == 1) {
                            std.debug.print("\nGuest finished\n", .{});
                            return;
                        }
                    },
                    0x24 => {
                        var val: u64 = undefined;
                        _ = hv.hv_vcpu_get_reg(vcpu, hv.HV_REG_X0, &val);

                        const char: u8 = @intCast(val & 0xFF);

                        std.debug.print("{c}", .{char});

                        var pc: u64 = undefined;

                        _ = hv.hv_vcpu_get_reg(vcpu, hv.HV_REG_PC, &pc);
                        _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_PC, pc + 4);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

// UART
const program_m4 = [_]u32{
    0xd2a12003, // mov x3, 0x9000000
    0x100001a4, // adr x4, message
    0xd2800185, // mov x5, #12
    0xd2800006, // mov x6, #0
    0xb9401861, // ldr w1, [x3, #0x18]
    0x721b003f, // tst w1, #0x20
    0x54ffffc1, // b.ne -2
    0x38666880, // ldrb w0, [x4,x6]
    0xb9000060, // str w0, [x3]
    0x910004c6, // add x6, x6, #1
    0xeb0500df, // cmp x6,x5
    0x54ffff2b, // b.lt -7
    0xd2800022, // mov x2, #1
    0xd4000002, // hvc #0

    // "Hello UART!\n" as raw bytes
    0x6c6c6548,
    0x4155206f,
    0x0a215452,
};

fn handler_m4(vcpu: hv.hv_vcpu_t, exit: ?*hv.hv_vcpu_exit_t) void {
    while (true) {
        const stat = hv.hv_vcpu_run(vcpu);

        if (stat != hv.HV_SUCCESS) {
            std.debug.panic("unknown exit status. status: {d}\n", .{stat});
        }

        const reason = exit.?.reason;

        if (reason != hv.HV_EXIT_REASON_EXCEPTION) {
            std.debug.panic("unknown exit reason. reason: {d}\n", .{reason});
        }

        const syndrome = exit.?.exception.syndrome;

        switch (syndrome >> 26) {
            0x16 => {
                var done: u64 = undefined;
                _ = hv.hv_vcpu_get_reg(vcpu, hv.HV_REG_X2, &done);

                if (done == 1) {
                    std.debug.print("\nGuest finished\n", .{});
                    return;
                }
            },
            0x24 => {
                const wnr = (syndrome >> 6) & 0x1;
                const srt: u32 = @intCast((syndrome >> 16) & 0x1F);
                const addr = exit.?.exception.physical_address;
                switch (wnr) {
                    // read
                    0x0 => {
                        _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_X0 + srt, 0x0);
                    },
                    // write
                    else => {
                        if (addr == 0x9_000_000) {
                            var val: u64 = undefined;
                            _ = hv.hv_vcpu_get_reg(vcpu, hv.HV_REG_X0 + srt, &val);

                            const char: u8 = @intCast(val & 0xFF);

                            std.debug.print("{c}", .{char});
                        }
                    },
                }
                var pc: u64 = undefined;
                _ = hv.hv_vcpu_get_reg(vcpu, hv.HV_REG_PC, &pc);
                _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_PC, pc + 4);
            },
            else => {},
        }
    }
}

fn kernel_handler(vcpu: hv.hv_vcpu_t, exit: ?*hv.hv_vcpu_exit_t) void {
    while (true) {
        const stat = hv.hv_vcpu_run(vcpu);

        if (stat != hv.HV_SUCCESS) {
            std.debug.panic("VM Run failed. status: {d}\n", .{stat});
        }

        const reason = exit.?.reason;

        switch (reason) {
            hv.HV_EXIT_REASON_EXCEPTION => {
                const syndrome = exit.?.exception.syndrome;
                const ec = syndrome >> 26;

                if (ec == 0x24) {
                    const wnr = (syndrome >> 6) & 0x1;
                    const srt: u32 = @intCast((syndrome >> 16) & 0x1F);
                    const addr = exit.?.exception.physical_address;

                    if (addr >= 0x09000000 and addr < 0x09001000) {
                        if (wnr == 0) {
                            _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_X0 + srt, 0x0);
                        } else {
                            if (addr == 0x09000000) {
                                var val: u64 = undefined;
                                _ = hv.hv_vcpu_get_reg(vcpu, hv.HV_REG_X0 + srt, &val);
                                const char: u8 = @intCast(val & 0xFF);
                                std.debug.print("{c}", .{char});
                            }
                        }
                    } else if (addr >= 0x08000000 and addr < 0x09000000) {
                        if (wnr == 0) {
                            _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_X0 + srt, 0x0);
                        }
                    } else {
                        std.debug.print("Unhanded MMIO: addr=0x{x}, isWrite={d}\n", .{ addr, wnr });
                    }

                    var pc: u64 = undefined;
                    _ = hv.hv_vcpu_get_reg(vcpu, hv.HV_REG_PC, &pc);
                    _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_PC, pc + 4);
                } else if (ec == 0x16) {
                    var x0: u64 = undefined;
                    _ = hv.hv_vcpu_get_reg(vcpu, hv.HV_REG_X0, &x0);

                    std.debug.print("[VMM] HVC call: x0=0x{x}\n", .{x0});

                    const PSCI_0_2_FN_VERSION = 0x84000000;
                    const PSCI_0_2_FN_CPU_ON = 0x84000003;
                    const PSCI_0_2_FN_MIGRATE_INFO_TYPE = 0x84000006;
                    const PSCI_0_2_FN_SYSTEM_OFF = 0x84000008;
                    const PSCI_0_2_FN_SYSTEM_RESET = 0x84000009;

                    const PSCI_RET_NOT_SUPPORTED: u64 = 0xFFFFFFFFFFFFFFFF;

                    if (x0 == PSCI_0_2_FN_VERSION) {
                        _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_X0, 2);
                    } else if (x0 == PSCI_0_2_FN_SYSTEM_OFF or x0 == PSCI_0_2_FN_SYSTEM_RESET) {
                        std.debug.print("\n[VM Shutdown via PSCI]\n", .{});
                        return;
                    } else if (x0 == PSCI_0_2_FN_CPU_ON) {
                        _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_X0, PSCI_RET_NOT_SUPPORTED);
                    } else if (x0 == PSCI_0_2_FN_MIGRATE_INFO_TYPE) {
                        _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_X0, 2);
                    } else {
                        if ((x0 & 0xFFFFFF00) == 0x84000000 or (x0 & 0xFFFFFF00) == 0xC4000000) {
                            _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_X0, PSCI_RET_NOT_SUPPORTED);
                        } else {
                            std.debug.print("Unhandled HVC: x0=0x{x}\n", .{x0});
                        }
                    }
                } else if (ec == 0x18) {
                    const is_write = (syndrome >> 0) & 0x1;
                    const rt: u32 = @intCast((syndrome >> 5) & 0x1F);

                    if (is_write == 0) {
                        _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_X0 + rt, 0x0);
                    }
                    var pc: u64 = undefined;
                    _ = hv.hv_vcpu_get_reg(vcpu, hv.HV_REG_PC, &pc);
                    _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_PC, pc + 4);
                } else if (ec == 0x01) {
                    var pc: u64 = undefined;
                    _ = hv.hv_vcpu_get_reg(vcpu, hv.HV_REG_PC, &pc);
                    _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_PC, pc + 4);
                } else {
                    std.debug.print("[VMM] Unhandled EC=0x{x}, syndrome=0x{x}\n", .{ ec, syndrome });
                    var pc: u64 = undefined;
                    _ = hv.hv_vcpu_get_reg(vcpu, hv.HV_REG_PC, &pc);
                    _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_PC, pc + 4);
                }
            },
            else => {
                std.debug.panic("Unhandled Exit Reason: {d}\n", .{reason});
            },
        }
    }
}
