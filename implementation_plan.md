# Pinocchio VMM — Resumption Guide

## Where You Are Now

### ✅ Completed
| File | Status | Notes |
|------|--------|-------|
| `build.zig` | Done | Hypervisor.framework linked, entitlements, translate-C |
| `src/hypervisor/hv.zig` | Done | Error set, `check()`, type re-exports |
| `src/hypervisor/macos.zig` | Done | `Vm.init/deinit`, `mapMemory`, `unmapMemory` |
| `src/memory.zig` | Done | `Gpa` type, `GuestMemory` with read/write/init/deinit |
| `guest/pinocchio.dts` | Done | DTS with memory, CPU, PSCI, GIC, UART, timer |
| `guest/pinocchio.dtb` | Done | Compiled DTB |
| `guest/vmlinuz` | Done | ARM64 Linux kernel image |
| `guest/init` | Done | Compiled init binary (1MB, statically linked) |

### ⬜ Stub files (empty or skeleton)
| File | Status |
|------|--------|
| `src/vcpu.zig` | Skeleton — `pub const Vcpu = struct {};` |
| `src/devices/mmio.zig` | Empty |
| `src/devices/uart.zig` | Empty |
| `src/devices/virtio/queue.zig` | Empty |
| `src/devices/virtio/net.zig` | Empty |
| `src/devices/virtio/blk.zig` | Empty |
| `src/devices/virtio/vsock.zig` | Empty |

### What Already Worked (in `main.zig`, now commented out)
Your old `main.zig` had a working **monolithic** kernel boot path — it could:
1. Load DTB and kernel into guest memory
2. Create a vCPU, set PC/X0/CPSR
3. Run a vCPU loop handling: MMIO traps (UART write at `0x09000000`), PSCI HVC calls, GIC register stubs, MSR/MRS traps
4. Boot Linux to the point where it emits serial output

That working code is your **reference implementation**. The task now is to decompose it into proper modules.

---

## Next Step: `vcpu.zig`

This is the right next file because:
- `memory.zig` and `macos.zig` are done — you can allocate guest memory and create a VM
- The vCPU is the **execution engine** — it's what runs guest code and produces exits
- Everything downstream (UART, MMIO, virtio) is *called from* the vCPU exit handler, so the vCPU module needs to exist first

### What `vcpu.zig` Needs to Do

The vCPU module has **three responsibilities**:

#### 1. Lifecycle Management (create / destroy)
- Call `hv_vcpu_create()` — this gives you a `hv_vcpu_t` handle and a pointer to `hv_vcpu_exit_t`
- Set initial register state (PC, X0, CPSR) — these are the "boot registers" that tell the guest where to start executing
- Call `hv_vcpu_destroy()` on teardown

#### 2. The Run Loop
The core of any VMM. The pattern is:

```
loop {
    hv_vcpu_run(vcpu)     ← guest runs until something happens
    examine exit reason    ← why did the guest stop?
    handle the exit        ← emulate the thing the guest tried to do
    (modify registers/memory as needed)
    continue               ← go back to the top
}
```

This is conceptually identical to your `kernel_handler()` function in the old `main.zig`. The key insight: **the guest doesn't know it stopped**. From its perspective, a MMIO store just takes a few hundred nanoseconds longer than a normal store. The VMM silently handles it and resumes.

#### 3. Exit Dispatch
When `hv_vcpu_run()` returns, the guest stopped for a reason. On AArch64 via Hypervisor.framework, the exit reasons you care about are:

| Exit Reason | Meaning | How to Handle |
|-------------|---------|---------------|
| `HV_EXIT_REASON_EXCEPTION` | Guest did something that traps to EL2 | Decode the **syndrome** (ESR_EL2) to find out what |
| `HV_EXIT_REASON_CANCELED` | Another thread called `hv_vcpu_cancel()` | Used for clean shutdown from another thread |

The syndrome's **Exception Class (EC)** field (bits [31:26]) tells you *what kind* of trap:

| EC | Meaning | Your Action |
|----|---------|-------------|
| `0x24` | Data abort (MMIO) | Decode the faulting address, read/write direction, and target register. Dispatch to your device (UART, GIC, etc.) |
| `0x16` | HVC instruction (PSCI) | Read X0 for the PSCI function ID. Return appropriate values. |
| `0x18` | MSR/MRS trap (system register) | Guest tried to access a system register that's trapped. Usually return 0 for stubbed registers. |
| `0x01` | WFI/WFE trapped | Guest is idle/waiting for interrupt. Either return immediately or sleep the host thread briefly. |

> [!IMPORTANT]
> **This is the syndrome you already decoded in `kernel_handler()`!** The logic is identical — you're just moving it into a proper struct with methods instead of a flat function.

---

## Conceptual Deep Dive: Why the vCPU Exit Loop Works

### The Two Worlds Model

```
┌─────────────────────────┐     ┌─────────────────────────┐
│    HOST (EL1/EL0)       │     │    GUEST (EL1/EL0)      │
│                         │     │                         │
│  Your Zig VMM process   │     │  Linux kernel           │
│  (vmmd)                 │     │  (thinks it owns HW)    │
│                         │     │                         │
│  hv_vcpu_run() ─────────┼─────┼→ resumes execution      │
│                         │     │                         │
│  ← returns with exit  ←─┼─────┼─ guest traps            │
│                         │     │                         │
│  handle exit, resume    │     │  doesn't know it stopped │
└─────────────────────────┘     └─────────────────────────┘
                    ↕
          ┌─────────────────┐
          │  Hypervisor.fw  │
          │  (EL2 / macOS)  │
          │  manages world  │
          │  switches       │
          └─────────────────┘
```

When you call `hv_vcpu_run()`:
1. Hypervisor.framework performs a **world switch** into the guest
2. The guest's register state is loaded, including its own page tables (stage-1)
3. Guest code runs at full hardware speed (not emulated!)
4. When the guest does something that can't be handled in the guest world (MMIO, HVC, trapped MSR), hardware raises an exception to EL2
5. Hypervisor.framework catches it, saves guest state, and returns control to your VMM thread
6. Your code reads the exit info, handles it, and calls `hv_vcpu_run()` again

### MMIO Trap Mechanics (Data Abort, EC=0x24)

This is the most common exit you'll handle. When the guest does:
```asm
str w0, [x3]    ; where x3 = 0x09000000 (UART base)
```

The hardware does:
1. Stage-2 translation: IPA `0x09000000` → **no mapping** (you never called `hv_vm_map` for this region)
2. Hardware raises a **data abort** at EL2
3. Hypervisor.framework fills in `hv_vcpu_exit_t`:
   - `reason = HV_EXIT_REASON_EXCEPTION`
   - `exception.syndrome` = ESR_EL2 value (contains EC, WnR, SRT, etc.)
   - `exception.physical_address` = `0x09000000`
4. `hv_vcpu_run()` returns to your code

The syndrome register encodes everything you need:
- **EC** (bits [31:26]): `0x24` = data abort from lower EL
- **WnR** (bit [6]): 0 = read, 1 = write
- **SRT** (bits [20:16]): which register (e.g., X0 → 0, X3 → 3)
- **SAS** (bits [23:22]): access size (00=byte, 01=halfword, 10=word, 11=doubleword)

Your handler then:
1. Looks at the physical address to decide which device owns it
2. Reads the value from the guest register (for writes) or computes a return value (for reads)
3. Advances PC by 4 (the faulting instruction is NOT automatically re-executed)

---

## Design Questions to Think About

Before you start writing `vcpu.zig`, consider:

1. **Who owns the exit dispatch?** Should `Vcpu` have a `run()` method that internally loops and dispatches, or should it expose a `step()` that runs one iteration and returns the exit info to the caller? 
   - Option A: `vcpu.run(handler)` — vCPU owns the loop, calls a handler interface
   - Option B: `while (true) { const exit = vcpu.step(); switch (exit) { ... } }` — caller owns the loop
   - Your old code was Option B (the `while(true)` in `kernel_handler`). Firecracker uses Option A.

2. **How does the vCPU communicate with devices?** Right now, the UART handling is inline in the exit handler. Eventually you'll want an MMIO bus that routes addresses to devices. But for *this* step, you could keep UART inline and extract it later.

3. **Boot register setup** — should `Vcpu` have a `set_boot_regs(kernel_addr, dtb_addr)` method, or should the caller set registers individually?

---

## Reading Before Writing vcpu.zig

Since you've already read the ARM virtualization guide, you're in good shape. Here's what to review specifically:

### Must Read
1. **Your own `kernel_handler()` in main.zig** (lines 249–348) — this IS your vCPU module in flat form. Read it carefully and note every exit type you handled.

2. **ARM Architecture Reference Manual (you have it as PDF)**:
   - **ESR_EL2 encoding** — Section D13.2.37 in the ARMv8 ARM. This is the syndrome register. Understand the bit layout for EC, IL, ISS.
   - **Data Abort ISS encoding** — Section D13.2.37 subsection for EC=0x24. The bit fields for SRT, SAS, WnR.

3. **Hypervisor.framework header** — specifically the `hv_vcpu_exit_t` struct layout and the register constants (HV_REG_X0 through HV_REG_X30, HV_REG_PC, HV_REG_CPSR, etc.)

### Recommended
4. **Firecracker `vstate/vcpu.rs`** — [GitHub link](https://github.com/firecracker-microvm/firecracker/blob/main/src/vmm/src/vstate/vcpu/mod.rs). Look at:
   - How they structure the vCPU run loop
   - How they handle KVM exits (conceptually the same as HF exits)
   - The `KvmVcpu` struct and what state it holds

5. **crosvm `vcpu.rs`** — [GitHub link](https://github.com/nicefunfarm/nicefunfarm-crosvm/blob/main/src/crosvm/sys/unix/vcpu.rs). Another reference VMM. Their vCPU module is cleaner for learning from.

---

## Roadmap After vcpu.zig

Once `vcpu.zig` is done (Vcpu struct, init/deinit, run loop, syndrome decoding):

```
vcpu.zig (you are here)
    ↓
Integrate in main.zig — boot Linux again using the new modules
    ↓
devices/uart.zig — extract UART handling from the vCPU exit handler
    ↓
devices/mmio.zig — MMIO bus that routes addresses → devices
    ↓
Re-integrate — vCPU exit handler dispatches to MMIO bus, MMIO bus dispatches to UART
    ↓
devices/virtio/queue.zig — virtqueue implementation
    ↓
devices/virtio/blk.zig — block device (rootfs disk)
    ↓
Boot Linux with a rootfs!
```

Each step is incremental and testable. After `vcpu.zig` + integration, you should be able to boot Linux again — same as before, but with clean module boundaries.
