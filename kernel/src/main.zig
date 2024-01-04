const std = @import("std");
const log = std.log;
const mem = std.mem;
const dtb = @import("dtb");

pub const std_options = struct {
    pub const logFn = @import("log.zig").logFn;
};





extern const fdt_address: [*]const u8;

export fn main() noreturn {
    log.info("Kernel booting...", .{});
    log.debug("FDT address: {*}", .{fdt_address});

    var traverser: dtb.Traverser = undefined;
    traverser.init(fdt_address) catch @panic("Invalid device tree");

    const State = enum {
        start,
        chosen,
        memory,
        plic,
        clint,
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
                }
            },
            .Prop => |p| {
                switch (state) {
                    .chosen => {
                        if (mem.eql(u8, p.name, "linux,initrd-start")) {
                            initrd_start = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value))).*);
                        } else if (mem.eql(u8, p.name, "linux,initrd-end")) {
                            initrd_end = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value))).*);
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
                    else => continue,
                }
            },
            .EndNode => {
                state = .start;
            },
            .End => break,
        }
    }
    log.debug("initrd_start: {?x}, initrd_end: {?x}", .{ initrd_start, initrd_end });
    log.debug("memory_start: {?x}, memory_size: {?x}", .{ memory_start, memory_size });
    log.debug("plic_start: {?x}, plic_size: {?x}", .{ plic_start, plic_size });
    log.debug("clint_start: {?x}, clint_size: {?x}", .{ clint_start, clint_size });
    while (true) {}
}
