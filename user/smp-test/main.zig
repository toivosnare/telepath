const page_size = @import("std").heap.pageSize();
const libt = @import("libt");
const service = libt.service;
const syscall = libt.syscall;

pub const std_options = libt.std_options;

comptime {
    _ = libt;
}

extern var serial: service.SerialDriver;
const writer = serial.tx.writer();

pub fn main(args: []usize) !void {
    _ = args;
    try writer.writeAll("Hello from smp-test.\n");

    // Allocate and map a stack for the thread.
    const stack_pages = 16;
    const stack_handle = try syscall.regionAllocate(.self, stack_pages, .{ .read = true, .write = true }, null);
    const stack_start: [*]align(page_size) u8 = @ptrCast(try syscall.regionMap(.self, stack_handle, null));
    const stack_end = stack_start + stack_pages * page_size;

    _ = try syscall.threadAllocate(.self, .self, @ptrCast(&writeInLoop), stack_end, 7, 'B', 2_000_000);
    try writeInLoop('A', 1_000_000);
}

fn writeInLoop(letter: u8, delay: usize) callconv(.c) noreturn {
    libt.sleep(delay / 2) catch unreachable;

    while (true) {
        writer.writeByte(letter) catch unreachable;
        libt.sleep(delay) catch unreachable;
    }
}
