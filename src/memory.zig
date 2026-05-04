const std = @import("std");
const hv = @import("hypervisor/hv.zig");
const testing = std.testing;
const macos = @import("hypervisor/macos.zig");

pub const Gpa = struct {
    addr: u64,

    pub fn init(addr: u64) Gpa {
        return Gpa{
            .addr = addr,
        };
    }

    pub fn asInt(self: Gpa) u64 {
        return self.addr;
    }
};

pub const GuestMemory = struct {
    base: Gpa,
    size: usize,
    host_memory: []align(std.heap.page_size_min) u8,

    pub fn init(base_addr: Gpa, size: usize) !GuestMemory {
        const mem = try std.posix.mmap(
            null,
            size,
            .{
                .READ = true,
                .WRITE = true,
            },
            .{
                .TYPE = .PRIVATE,
                .ANONYMOUS = true,
            },
            -1,
            0,
        );
        errdefer std.posix.munmap(mem);
        // TODO: define this in macos.zig
        try macos.mapMemory(mem.ptr, base_addr.asInt(), size, hv.HV_MEMORY_READ | hv.HV_MEMORY_WRITE | hv.HV_MEMORY_EXEC);
        return GuestMemory{
            .base = base_addr,
            .size = size,
            .host_memory = mem,
        };
    }

    pub fn deinit(self: GuestMemory) void {
        macos.unmapMemory(self.base.asInt(), self.size);
        std.posix.munmap(self.host_memory);
    }

    pub fn read(self: *GuestMemory, comptime T: type, gpa: Gpa) Error!T {
        const gpa_addr = gpa.asInt();
        const base_addr = self.base.asInt();

        if (gpa_addr < base_addr) {
            return Error.OutOfBounds;
        }

        const offset: usize = @intCast(gpa_addr - base_addr);

        if (offset + @sizeOf(T) > self.size) {
            return Error.OutOfBounds;
        }

        const ptr_u8: [*]u8 = self.host_memory.ptr + offset;

        const ptr_T: *align(1) const T = @ptrCast(ptr_u8);

        return ptr_T.*;
    }

    pub fn write(self: *GuestMemory, comptime T: type, gpa: Gpa, value: T) Error!void {
        const gpa_addr = gpa.asInt();
        const base_addr = self.base.asInt();

        if (gpa_addr < base_addr) {
            return Error.OutOfBounds;
        }

        const offset: usize = @intCast(gpa_addr - base_addr);

        if (offset + @sizeOf(T) > self.size) {
            return Error.OutOfBounds;
        }

        const ptr_u8: [*]u8 = self.host_memory.ptr + offset;

        const ptr_T: *align(1) T = @ptrCast(ptr_u8);

        ptr_T.* = value;
    }
};

pub const RAM_BASE = Gpa.init(0x40000000);

pub const Error = error{
    OutOfBounds,
    MapFailed,
};

test "allocates guest memory" {
    const ram_size: usize = 128 * 1024 * 1024;
    const ram = try GuestMemory.init(RAM_BASE, ram_size);

    try testing.expectEqual(ram.host_memory.len, ram_size);
}
