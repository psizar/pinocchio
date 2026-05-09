const std = @import("std");
const macos = @import("hypervisor/macos.zig");
const memory = @import("memory.zig");
const vcpu = @import("vcpu.zig");
const hv = @import("hypervisor/hv.zig");

pub fn main(init: std.process.Init) !void {
    var vm = try macos.Vm.init();
    defer vm.deinit();

    var ram = try memory.GuestMemory.init(memory.RAM_BASE, 128 * 1024 * 1024);
    defer ram.deinit();
    var cpu = try vcpu.Vcpu.init();
    defer cpu.deinit();
    _ = try loadFile(init.io, ram.host_memory[0..], "guest/pinocchio.dtb");
    _ = try loadFile(init.io, ram.host_memory[0x200000..], "guest/vmlinuz");
    _ = try loadFile(init.io, ram.host_memory[0x4000000..], "guest/initramfs.cpio.gz");

    try cpu.setBootRegs(memory.RAM_BASE.asInt() + 0x020_0000, memory.RAM_BASE.asInt());

    var timer_pending: bool = false;
    while (true) {
        const exit = try cpu.step();
        const reason = exit.reason;
        switch (reason) {
            hv.EXIT_REASON_EXCEPTION => {
                const syndrome = exit.exception.syndrome;
                const ec = syndrome >> 26;
                const REG_X0: u32 = @intCast(hv.HV_REG_X0);

                switch (ec) {
                    0x24 => {
                        const isv = (syndrome >> 24) & 0x1;
                        const sas: u2 = @intCast((syndrome >> 22) & 0x3);
                        const sse = (syndrome >> 21) & 0x1;
                        const srt: u32 = @intCast((syndrome >> 16) & 0x1F);
                        const sf = (syndrome >> 15) & 0x1;
                        const wnr = (syndrome >> 6) & 0x1;
                        const addr = exit.exception.physical_address;

                        _ = sse;
                        _ = sf;

                        if (isv == 0) {
                            std.debug.print("[VMM] ec={}, ISV={} at addr=0x{x} - cannot decode syndrome skipping\n", .{ ec, isv, addr });
                            const pc = try cpu.getReg(hv.HV_REG_PC);
                            try cpu.setReg(hv.HV_REG_PC, pc + 4);
                            continue;
                        }

                        if (addr >= 0x09000000 and addr < 0x09001000) {
                            if (wnr == 0) {
                                var val: u64 = 0;
                                const offset = addr - 0x09000000;
                                if (offset == 0xFE0) val = 0x11 else if (offset == 0xFE4) val = 0x10 else if (offset == 0xFE8) val = 0x14 else if (offset == 0xFEC) val = 0x00 else if (offset == 0xFF0) val = 0x0D else if (offset == 0xFF4) val = 0xF0 else if (offset == 0xFF8) val = 0x05 else if (offset == 0xFFC) val = 0xB1 else if (offset == 0x018) val = 0x90; // UARTFR

                                try cpu.setReg(REG_X0 + srt, sasMask(sas, val));
                            } else {
                                if (addr == 0x09000000) {
                                    const val: u64 = try cpu.getReg(REG_X0 + srt);
                                    const char: u8 = @truncate(sasMask(sas, val));
                                    std.debug.print("{c}", .{char});
                                }
                            }
                        } else if (addr >= 0x08000000 and addr < 0x09000000) {
                            if (wnr == 0) {
                                var gic_val: u64 = 0;
                                if (addr < 0x08010000) {
                                    const offset = addr - 0x08000000;
                                    if (offset == 0xFFE8) gic_val = 0x3B; // GICD_PIDR2
                                } else if (addr >= 0x080A0000) {
                                    const offset = addr - 0x080A0000;
                                    if (offset == 0xFFE8) gic_val = 0x3B; // GICR_PIDR2
                                    if (offset == 0x0008) gic_val = 0x10; // GICR_TYPER: Last=1
                                }
                                try cpu.setReg(REG_X0 + srt, sasMask(sas, gic_val));
                            }
                        } else {
                            std.debug.print("Unhanded MMIO: addr=0x{x}, isWrite={d}\n", .{ addr, wnr });
                        }

                        const pc: u64 = try cpu.getReg(hv.HV_REG_PC);
                        try cpu.setReg(hv.HV_REG_PC, pc + 4);
                    },
                    0x16 => {
                        const x0: u64 = try cpu.getReg(hv.HV_REG_X0);

                        std.debug.print("[VMM] HVC call: x0=0x{x}\n", .{x0});

                        const PSCI_0_2_FN_VERSION = 0x84000000;
                        const PSCI_0_2_FN_CPU_ON = 0x84000003;
                        const PSCI_0_2_FN_MIGRATE_INFO_TYPE = 0x84000006;
                        const PSCI_0_2_FN_SYSTEM_OFF = 0x84000008;
                        const PSCI_0_2_FN_SYSTEM_RESET = 0x84000009;

                        const PSCI_RET_NOT_SUPPORTED: u64 = 0xFFFFFFFFFFFFFFFF;

                        if (x0 == PSCI_0_2_FN_VERSION) {
                            try cpu.setReg(hv.HV_REG_X0, 2);
                        } else if (x0 == PSCI_0_2_FN_SYSTEM_OFF or x0 == PSCI_0_2_FN_SYSTEM_RESET) {
                            std.debug.print("\n[VM Shutdown via PSCI]\n", .{});
                            return;
                        } else if (x0 == PSCI_0_2_FN_CPU_ON) {
                            try cpu.setReg(hv.HV_REG_X0, PSCI_RET_NOT_SUPPORTED);
                        } else if (x0 == PSCI_0_2_FN_MIGRATE_INFO_TYPE) {
                            try cpu.setReg(hv.HV_REG_X0, 2);
                        } else {
                            if ((x0 & 0xFFFFFF00) == 0x84000000 or (x0 & 0xFFFFFF00) == 0xC4000000) {
                                try cpu.setReg(hv.HV_REG_X0, PSCI_RET_NOT_SUPPORTED);
                            } else {
                                std.debug.print("Unhandled HVC: x0=0x{x}\n", .{x0});
                            }
                        }
                    },
                    0x18 => {
                        const is_write = (syndrome >> 0) & 0x1;
                        const rt: u32 = @intCast((syndrome >> 5) & 0x1F);
                        const crm = (syndrome >> 1) & 0xF;
                        const crn = (syndrome >> 10) & 0xF;
                        const op1 = (syndrome >> 14) & 0x7;
                        const op2 = (syndrome >> 17) & 0x7;
                        const op0 = (syndrome >> 20) & 0x3;

                        if (is_write == 0) {
                            var val: u64 = 0;
                            if (op0 == 3 and op1 == 0 and crn == 12 and crm == 12) {
                                if (op2 == 5) {
                                    val = 0x7; // ICC_SRE_EL1
                                } else if (op2 == 0) {
                                    // ICC_IAR1_EL1
                                    if (timer_pending) {
                                        val = 27; // Virtual Timer PPI
                                        timer_pending = false; // Acknowledged
                                    } else {
                                        val = 1023; // Spurious
                                    }
                                }
                            }
                            if (rt < 31) {
                                try cpu.setReg(REG_X0 + rt, val);
                            }
                        } else {
                            if (op0 == 3 and op1 == 0 and crn == 12 and crm == 12 and op2 == 1) {
                                // ICC_EOIR1_EL1
                                try macos.vcpuSetVtimerMask(cpu.handle, false);
                                try macos.vcpuSetPendingInterrupt(cpu.handle, hv.HV_INTERRUPT_TYPE_IRQ, false);
                            }
                        }
                        const pc: u64 = try cpu.getReg(hv.HV_REG_PC);
                        try cpu.setReg(hv.HV_REG_PC, pc + 4);
                    },
                    0x01 => {
                        const pc: u64 = try cpu.getReg(hv.HV_REG_PC);
                        try cpu.setReg(hv.HV_REG_PC, pc + 4);
                    },
                    else => {
                        std.debug.print("[VMM] Unhandled EC=0x{x}, syndrome=0x{x}\n", .{ ec, syndrome });
                        const pc: u64 = try cpu.getReg(hv.HV_REG_PC);
                        try cpu.setReg(hv.HV_REG_PC, pc + 4);
                    },
                }
            },
            hv.EXIT_REASON_VTIMER_ACTIVATED => {
                try macos.vcpuSetVtimerMask(cpu.handle, true);
                try macos.vcpuSetPendingInterrupt(cpu.handle, hv.HV_INTERRUPT_TYPE_IRQ, true);
                timer_pending = true;
            },
            else => {
                std.debug.panic("Unhandled Exit Reason: {d}\n", .{reason});
            },
        }
    }
}

fn sasMask(sas: u2, val: u64) u64 {
    return switch (sas) {
        0 => val & 0xFF,
        1 => val & 0xFFFF,
        2 => val & 0xFFFFFFFF,
        3 => val,
    };
}

fn loadFile(io: std.Io, buffer: []u8, path: []const u8) !usize {
    const fileSlice = try std.Io.Dir.cwd().readFile(io, path, buffer);

    return fileSlice.len;
}
