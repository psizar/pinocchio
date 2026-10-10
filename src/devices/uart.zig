const std = @import("std");

pub fn read(offset: u64, size: u8) u64 {
    _ = size;

    return switch (offset) {
        0x018 => 0x90,
        0xFE0 => 0x11,
        0xFE4 => 0x10,
        0xFE8 => 0x14,
        0xFEC => 0x00,
        0xFF0 => 0x0D,
        0xFF4 => 0xF0,
        0xFF8 => 0x05,
        0xFFC => 0xB1,
        else => 0,
    };
}

pub fn write(offset: u64, size: u8, value: u64) void {
    _ = size;

    if (offset == 0x000) {
        const char: u8 = @truncate(value);
        std.debug.print("{c}", .{char});
    }
}
