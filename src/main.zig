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

    const guest_mem_size = std.heap.pageSize();

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
    loadProgram(buffer, &program_m4);

    const map_ret = hv.hv_vm_map(buffer.ptr, 0x0, guest_mem_size, hv.HV_MEMORY_READ | hv.HV_MEMORY_EXEC);
    std.debug.print("map returned: 0x{x}\n", .{@as(u32, @bitCast(map_ret))});

    // execute(handler_m2);
    // execute(handler_m3);
    execute(handler_m4);
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

    _ = hv.hv_vcpu_set_reg(vcpu, hv.HV_REG_PC, 0x0); // set to first instr
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
