const std = @import("std");
const atomic = std.atomic;
const math = std.math;

pub const MmioRegisters = extern struct {
    magic_value: u32,
    version: u32,
    device_id: enum(u32) {
        reserved = 0,
        block_device = 2,
        _,
    },
    vendor_id: u32,
    device_features: u32,
    device_features_sel: u32,
    _reserved0: [2]u32,
    driver_features: u32,
    driver_features_sel: u32,
    _reserved1: [2]u32,
    queue_sel: u32,
    queue_num_max: u32,
    queue_num: u32,
    _reserved2: [2]u32,
    queue_ready: u32,
    _reserved3: [2]u32,
    queue_notify: extern union {
        index: u32,
        data: packed struct(u32) {
            vqn: u16,
            next_off: u15,
            next_wrap: u1,
        },
    },
    _reserved4: [3]u32,
    interrupt_status: packed struct(u32) {
        used_buffer: bool,
        configuration_change: bool,
        _reserved: u30,
    },
    interrupt_acknowledge: packed struct(u32) {
        used_buffer: bool,
        configuration_change: bool,
        _reserved: u30,
    },
    _reserved5: [2]u32,
    status: u32,
    _reserved6: [3]u32,
    queue_desc_low: u32,
    queue_desc_high: u32,
    _reserved7: [2]u32,
    queue_driver_low: u32,
    queue_driver_high: u32,
    _reserved8: [2]u32,
    queue_device_low: u32,
    queue_device_high: u32,
    _reserved9: [21]u32,
    config_generation: u32,
    config: void,

    pub const magic: u32 = 0x74726976;

    pub const Status = enum(u32) {
        acknowledge = 1,
        driver = 2,
        driver_ok = 4,
        features_ok = 8,
        device_needs_reset = 64,
        failed = 128,
    };
};

pub fn Queue(l: usize) type {
    return struct {
        descriptors: [length]Descriptor,
        free_list_head: Index,
        available: Available,
        used: Used,

        pub const Self = @This();
        pub const length = l;
        pub const Index = u16;
        pub const chain_end = math.maxInt(Index);

        pub const Descriptor = extern struct {
            address: u64,
            length: u32,
            flags: packed struct(u16) {
                next: bool = false,
                write: bool = false,
                indirect: bool = false,
                _: u13 = 0,
            },
            next: Index,
        };

        pub const Available = extern struct {
            flags: packed struct(u16) {
                interrupt: bool = false,
                _: u15 = 0,
            },
            index: Index,
            ring: [length]Index,
            used_event: Index,
        };

        pub const Used = extern struct {
            flags: packed struct(u16) {
                no_notify: bool = false,
                _: u15 = 0,
            },
            index: Index,
            ring: [length]Element,
            avail_event: Index,

            pub const Element = extern struct {
                id: u32,
                length: u32,
            };
        };

        pub fn init(self: *Self) void {
            for (1.., &self.descriptors) |i, *descriptor| {
                descriptor.address = 0;
                descriptor.length = 0;
                descriptor.flags = .{};
                descriptor.next = @intCast(i);
            }
            self.descriptors[length - 1].next = chain_end;
            self.free_list_head = 0;

            self.available.flags = .{};
            self.available.index = 0;
            for (&self.available.ring) |*ring_element| {
                ring_element.* = 0;
            }
            self.available.used_event = 0;

            self.used.flags = .{};
            self.used.index = 0;
            for (&self.used.ring) |*ring_element| {
                ring_element.* = .{ .id = 0, .length = 0 };
            }
            self.used.avail_event = 0;
        }

        pub fn allocate(self: *Self) !Index {
            if (self.free_list_head == chain_end)
                return error.OutOfMemory;

            const index = self.free_list_head;
            const desc = &self.descriptors[index];
            self.free_list_head = desc.next;
            return index;
        }

        pub fn free(self: *Self, index: Index) void {
            const desc = &self.descriptors[index];
            desc.next = self.free_list_head;
            self.free_list_head = index;
        }
    };
}
