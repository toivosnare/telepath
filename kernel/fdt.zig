const std = @import("std");
const mem = std.mem;
const dtb = @import("dtb");
const mm = @import("mm.zig");
const proc = @import("proc.zig");
const PhysicalAddress = mm.PhysicalAddress;

const ParseResult = struct {
    fdt_size: usize,
    fdt_physical_end: PhysicalAddress,
    initrd_physical_start: PhysicalAddress,
    initrd_size: usize,
    initrd_physical_end: PhysicalAddress,
    ram_physical_start: PhysicalAddress,
    ram_size: usize,
    ram_physical_end: PhysicalAddress,
    plic_physical_start: PhysicalAddress,
    plic_size: usize,
    plic_physical_end: PhysicalAddress,
    clint_physical_start: PhysicalAddress,
    clint_size: usize,
    clint_physical_end: PhysicalAddress,
};
pub fn parse(fdt_physical_start: PhysicalAddress) ParseResult {
    var traverser: dtb.Traverser = undefined;
    traverser.init(@ptrFromInt(fdt_physical_start)) catch @panic("invalid device tree");

    const State = enum {
        start,
        chosen,
        memory,
        plic,
        clint,
        hart,
    };
    var state: State = .start;
    var initrd_start: ?u32 = null;
    var initrd_end: ?u32 = null;
    var memory_start: ?u32 = null;
    var memory_size: ?u32 = null;
    var plic_start: ?u32 = null;
    var plic_size: ?u32 = null;
    var clint_start: ?u32 = null;
    var clint_size: ?u32 = null;
    var hart_count: usize = 1;

    while (true) {
        const event = traverser.event() catch break;
        switch (event) {
            .BeginNode => |b| {
                if (mem.eql(u8, b, "chosen")) {
                    state = .chosen;
                } else if (mem.startsWith(u8, b, "memory")) {
                    state = .memory;
                } else if (mem.startsWith(u8, b, "plic")) {
                    state = .plic;
                } else if (mem.startsWith(u8, b, "clint")) {
                    state = .clint;
                } else if (mem.startsWith(u8, b, "cpu@")) {
                    state = .hart;
                }
            },
            .Prop => |p| {
                switch (state) {
                    .chosen => {
                        if (mem.eql(u8, p.name, "linux,initrd-start")) {
                            initrd_start = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[4..8]))).*);
                        } else if (mem.eql(u8, p.name, "linux,initrd-end")) {
                            initrd_end = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[4..8]))).*);
                        }
                    },
                    .memory => {
                        if (mem.eql(u8, p.name, "reg")) {
                            memory_start = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[4..8]))).*);
                            memory_size = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[12..16]))).*);
                        }
                    },
                    .plic => {
                        if (mem.eql(u8, p.name, "reg")) {
                            plic_start = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[4..8]))).*);
                            plic_size = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[12..16]))).*);
                        }
                    },
                    .clint => {
                        if (mem.eql(u8, p.name, "reg")) {
                            clint_start = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[4..8]))).*);
                            clint_size = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[12..16]))).*);
                        }
                    },
                    .hart => {
                        if (mem.eql(u8, p.name, "reg")) {
                            const hart_id = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value))).*);
                            if (hart_id != proc.hart_array[0].id) {
                                proc.hart_array[hart_count].id = hart_id;
                                hart_count += 1;
                            }
                        }
                    },
                    else => continue,
                }
            },
            .EndNode => {
                state = .start;
            },
            .End => break,
        }
    }
    if (initrd_start == null) {
        @panic("initrd start address was not found in the device tree.");
    } else if (initrd_end == null) {
        @panic("initrd end address was not found in the device tree.");
    } else if (initrd_end.? < initrd_start.?) {
        @panic("initrd end address is before start address.");
    } else if (memory_start == null) {
        @panic("memory start address was not found in the device tree.");
    } else if (memory_size == null) {
        @panic("memory size was not found in the device tree.");
    } else if (plic_start == null) {
        @panic("PLIC start address was not found in the device tree.");
    } else if (plic_size == null) {
        @panic("PLIC size was not found in the device tree.");
    } else if (clint_start == null) {
        @panic("CLINT start address was not found in the device tree.");
    } else if (clint_size == null) {
        @panic("CLINT size was not found in the device tree.");
    }
    proc.harts = proc.hart_array[0..hart_count];
    return .{
        .fdt_size = @intCast(traverser.header.totalsize),
        .fdt_physical_end = 0,
        .initrd_physical_start = @intCast(initrd_start.?),
        .initrd_size = @intCast(initrd_end.? - initrd_start.?),
        .initrd_physical_end = @intCast(initrd_end.?),
        .ram_physical_start = @intCast(memory_start.?),
        .ram_size = @intCast(memory_size.?),
        .ram_physical_end = @intCast(memory_start.? + memory_size.?),
        .plic_physical_start = @intCast(plic_start.?),
        .plic_size = @intCast(plic_size.?),
        .plic_physical_end = @intCast(plic_start.? + plic_size.?),
        .clint_physical_start = @intCast(clint_start.?),
        .clint_size = @intCast(clint_size.?),
        .clint_physical_end = @intCast(clint_start.? + clint_size.?),
    };
}
