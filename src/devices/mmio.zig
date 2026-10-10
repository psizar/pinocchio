const std = @import("std");

pub const Device = enum { uart, gic };

const Mapping = struct {
    range: AddressRange,
    device: Device,
};

pub const ResolvedAccess = struct { device: Device, offset: u64 };

pub const Bus = struct {
    allocator: std.mem.Allocator,
    mappings: std.ArrayList(Mapping) = .empty,

    pub fn init(allocator: std.mem.Allocator) Bus {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Bus) void {
        self.mappings.deinit(self.allocator);
    }

    pub fn register(
        self: *Bus,
        range: AddressRange,
        device: Device,
    ) !void {
        if (range.start >= range.end) return error.InvalidRange;

        for (self.mappings.items) |mapping| {
            if (range.overlaps(mapping.range)) {
                return error.OverlappingRange;
            }
        }

        try self.mappings.append(self.allocator, .{
            .range = range,
            .device = device,
        });
    }

    pub fn resolve(self: *const Bus, address: u64) error{UnmappedAddress}!ResolvedAccess {
        for (self.mappings.items) |mapping| {
            if (mapping.range.contains(address)) {
                return .{
                    .device = mapping.device,
                    .offset = address - mapping.range.start,
                };
            }
        }

        return error.UnmappedAddress;
    }
};

pub const AddressRange = struct {
    start: u64,
    end: u64,

    pub fn contains(self: AddressRange, address: u64) bool {
        return address >= self.start and address < self.end;
    }

    pub fn overlaps(self: AddressRange, other: AddressRange) bool {
        return self.start < other.end and other.start < self.end;
    }
};
