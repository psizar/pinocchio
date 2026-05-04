const hv = @import("hyper");

pub const Error = error{
    HvError,
    HvBusy,
    HvBadArgument,
    HvIllegalGuestState,
    HvNoResources,
    HvNoDevice,
    HvDenied,
    HvExists,
    HvUnsupported,
};

pub const VcpuT = hv.hv_vcpu_t;
pub const VcpuExitT = hv.hv_vcpu_exit_t;
pub const MemFlags = hv.hv_memory_flags_t;
pub const ExitReason = hv.hv_exit_reason_t;
pub const VmConfigT = hv.hv_vm_config_t;
pub const VcpuConfigT = hv.hv_vcpu_config_t;
pub const VcpuRegT = hv.hv_reg_t;

pub const HV_MEMORY_READ: u64 = hv.HV_MEMORY_READ;
pub const HV_MEMORY_WRITE: u64 = hv.HV_MEMORY_WRITE;
pub const HV_MEMORY_EXEC: u64 = hv.HV_MEMORY_EXEC;

pub const EXIT_REASON_EXCEPTION = hv.HV_EXIT_REASON_EXCEPTION;
pub const EXIT_REASON_CANCELED = hv.HV_EXIT_REASON_CANCELED;
pub const EXIT_REASON_VTIMER_ACTIVATED = hv.HV_EXIT_REASON_VTIMER_ACTIVATED;

pub const HV_REG_PC = hv.HV_REG_PC;
pub const HV_REG_X0 = hv.HV_REG_X0;
pub const HV_REG_CPSR = hv.HV_REG_CPSR;

pub fn check(ret: hv.hv_return_t) Error!void {
    return switch (ret) {
        hv.HV_ERROR => Error.HvError,
        hv.HV_BUSY => Error.HvBusy,
        hv.HV_BAD_ARGUMENT => Error.HvBadArgument,
        hv.HV_ILLEGAL_GUEST_STATE => Error.HvIllegalGuestState,
        hv.HV_NO_RESOURCES => Error.HvNoResources,
        hv.HV_NO_DEVICE => Error.HvNoDevice,
        hv.HV_DENIED => Error.HvDenied,
        hv.HV_EXISTS => Error.HvExists,
        hv.HV_UNSUPPORTED => Error.HvUnsupported,
        hv.HV_SUCCESS => {},
        else => Error.HvError,
    };
}

pub fn vmCreate(config: VmConfigT) Error!void {
    try check(hv.hv_vm_create(config));
}

pub fn vmDestroy() Error!void {
    try check(hv.hv_vm_destroy());
}

pub fn vmVcpuCreate(vcpu: *u64, exit: *?*VcpuExitT, config: VcpuConfigT) Error!void {
    try check(hv.hv_vcpu_create(vcpu, exit, config));
}

pub fn vmVcpuDestroy(vcpu: u64) Error!void {
    try check(hv.hv_vcpu_destroy(vcpu));
}

pub fn vmVcpuRun(vcpu: u64) Error!void {
    try check(hv.hv_vcpu_run(vcpu));
}

pub fn vmMemoryMap(host_addr: [*]u8, gpa: u64, size: usize, flags: MemFlags) Error!void {
    try check(hv.hv_vm_map(host_addr, gpa, size, flags));
}

pub fn vmMemoryUnmap(gpa: u64, size: usize) Error!void {
    try check(hv.hv_vm_unmap(gpa, size));
}

pub fn getReg(vcpu: u64, reg: VcpuRegT) !u64 {
    var val: u64 = undefined;
    try check(hv.hv_vcpu_get_reg(vcpu, reg, &val));

    return val;
}

pub fn setReg(vcpu: u64, reg: VcpuRegT, val: u64) !void {
    try check(hv.hv_vcpu_set_reg(vcpu, reg, val));
}

pub fn vcpuSetVtimerMask(vcpu: u64, is_masked: bool) !void {
    try check(hv.hv_vcpu_set_vtimer_mask(vcpu, is_masked));
}

pub const HV_INTERRUPT_TYPE_IRQ: u32 = @intCast(hv.HV_INTERRUPT_TYPE_IRQ);
pub const HV_INTERRUPT_TYPE_FIQ: u32 = @intCast(hv.HV_INTERRUPT_TYPE_FIQ);
pub fn vcpuSetPendingInterrupt(vcpu: u64, int_type: u32, pending: bool) Error!void {
    try check(hv.hv_vcpu_set_pending_interrupt(vcpu, int_type, pending));
}
