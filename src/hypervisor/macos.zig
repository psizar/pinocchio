const hv = @import("hv.zig");
const std = @import("std");

pub const Vm = struct {
    pub fn init() !Vm {
        // TODO: update configuration for VM create
        try hv.vmCreate(@as(hv.VmConfigT, null));

        return Vm{};
    }

    pub fn deinit(self: *Vm) void {
        _ = self;
        hv.vmDestroy() catch |err| {
            std.log.warn("Failed to destroy VM: {}", .{err});
        };
    }
};

pub fn mapMemory(host_addr: [*]u8, gpa: u64, size: usize, flags: hv.MemFlags) !void {
    try hv.vmMemoryMap(host_addr, gpa, size, flags);
}

pub fn unmapMemory(gpa: u64, size: usize) void {
    hv.vmMemoryUnmap(gpa, size) catch |err| {
        std.log.err("failed to unmap memory from VM: {}", .{err});
    };
}

pub fn vcpuCreate(vcpu: *u64, exit: *?*hv.VcpuExitT, config: hv.VcpuConfigT) !void {
    try hv.vmVcpuCreate(vcpu, exit, config);
}

pub fn vcpuDestroy(vcpu: u64) void {
    hv.vmVcpuDestroy(vcpu) catch |err| {
        std.log.err("failed to destroy vcpu: {}", .{err});
    };
}

pub fn vcpuRun(vcpu: u64) !void {
    try hv.vmVcpuRun(vcpu);
}

pub fn getReg(vcpu: u64, reg: hv.VcpuRegT) !u64 {
    return hv.getReg(vcpu, reg);
}

pub fn setReg(vcpu: u64, reg: hv.VcpuRegT, val: u64) !void {
    try hv.setReg(vcpu, reg, val);
}

pub fn vcpuSetVtimerMask(vcpu: u64, is_masked: bool) !void {
    try hv.vcpuSetVtimerMask(vcpu, is_masked);
}

pub fn vcpuSetPendingInterrupt(vcpu: u64, int_type: u32, pending: bool) !void {
    try hv.vcpuSetPendingInterrupt(vcpu, int_type, pending);
}
