const std = @import("std");
const log = std.log;
const mm = @import("./mm.zig");

const SSI: usize = 1 << 1;
const STI: usize = 1 << 5;
const SEI: usize = 1 << 9;
const STATUS_SIE: usize = 1 << 1;

pub fn init() void {
    asm volatile (
        \\csrw stvec, %[vec]
        \\csrw sie, %[mask]
        \\csrsi sstatus, %[status]
        :
        : [vec] "r" (@intFromPtr(&handleTrap)),
          [mask] "r" (SSI | STI | SEI),
          [status] "I" (STATUS_SIE),
    );
}

pub fn onAddressTranslationEnabled() void {
    asm volatile (
        \\csrw stvec, %[vec]
        :
        : [vec] "r" (@intFromPtr(&handleTrap) + mm.kernel_offset),
    );
}

extern fn handleTrap() callconv(.Naked) noreturn;

export fn handleTrap2(scause: usize, stval: usize) align(4) noreturn {
    log.debug("Trap: scause={}, stval={x}", .{ scause, stval });
    @panic("trap");
}
