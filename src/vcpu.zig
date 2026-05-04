const hv = @import("hypervisor/hv.zig"); // TODO: abstract away once KVM part is clear
const macos = @import("hypervisor/macos.zig");
const std = @import("std");

pub const Vcpu = struct {
    handle: hv.VcpuT,
    exit: *hv.VcpuExitT,

    pub fn init() !Vcpu {
        var handle: hv.VcpuT = undefined;
        var exit: ?*hv.VcpuExitT = undefined;
        // TODO: handle the config later for hv_vcpu_create
        try macos.vcpuCreate(&handle, &exit, null);
        // try macos.vcpuSetVtimerMask(handle, false);

        return Vcpu{
            .handle = handle,
            .exit = exit.?,
        };
    }

    pub fn deinit(self: *Vcpu) void {
        macos.vcpuDestroy(self.handle);
    }

    pub fn setBootRegs(self: *Vcpu, kernel_addr: u64, dtb_addr: u64) !void {
        try self.setReg(hv.HV_REG_PC, kernel_addr);
        try self.setReg(hv.HV_REG_X0, dtb_addr);
        try self.setReg(hv.HV_REG_CPSR, 0x3C5); // set PSTATE to EL1h
    }

    pub fn getReg(self: *Vcpu, reg: u32) !u64 {
        return macos.getReg(self.handle, reg);
    }

    pub fn setReg(self: *Vcpu, reg: u32, val: u64) !void {
        try macos.setReg(self.handle, reg, val);
    }

    pub fn step(self: *Vcpu) !*hv.VcpuExitT {
        try macos.vcpuRun(self.handle);

        return self.exit;
    }
};
