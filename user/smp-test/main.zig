const page_size = @import("std").mem.page_size;
const libt = @import("libt");
const syscall = libt.syscall;

comptime {
    _ = libt;
}

const services = @import("services");
const writer = services.serial.tx.writer();

pub fn main(args: []usize) !void {
    _ = args;
    try writer.writeAll("Hello from smp-test.\n");

    // Allocate and map a stack for the thread.
    const stack_pages = 16;
    const stack_handle = try syscall.regionAllocate(.self, stack_pages, .{ .read = true, .write = true }, null);
    const stack_start: [*]align(page_size) u8 = @ptrCast(try syscall.regionMap(.self, stack_handle, null));
    const stack_end = stack_start + stack_pages * page_size;

    _ = try syscall.threadAllocate(.self, .self, @ptrCast(&writeInLoop), stack_end, 'B', 2_000_000, 0);
    try writeInLoop('A', 1_000_000);
}

fn writeInLoop(letter: u8, delay: usize) noreturn {
    libt.sleep(delay / 2) catch unreachable;

    while (true) {
        writer.writeByte(letter) catch unreachable;
        libt.sleep(delay) catch unreachable;
    }
}
