const std = @import("std");
const root = @import("root");
const options = @import("options");

pub const syscall = @import("syscall.zig");
pub const tix = @import("tix.zig");

comptime {
    if (options.include_entry_point)
        @export(_start, .{ .name = "_start" });
}

fn _start() callconv(.Naked) noreturn {
    const max_virtual = 0x3FFFFFFFFF;
    // Allocate and map stack, jump to main.
    asm volatile (
        \\li a0, %[allocate_id]
        \\li a1, %[stack_size]
        \\li a2, %[stack_permissions]
        \\li a3, 0
        \\ecall
        \\bltz a0, 1f
        \\mv a1, a0
        \\li a0, %[map_id]
        \\mv a2, %[virtual_address]
        \\ecall
        \\bltz a0, 1f
        \\mv sp, %[stack_address]
        \\jr %[main]
        \\1:
        \\li a0, %[exit_id]
        \\li a1, 1
        \\ecall
        :
        : [allocate_id] "I" (@intFromEnum(syscall.Id.allocate)),
          [stack_size] "I" (options.stack_size),
          [stack_permissions] "I" (syscall.Permissions{ .readable = true, .writable = true }),
          [map_id] "I" (@intFromEnum(syscall.Id.map)),
          [virtual_address] "{t0}" (max_virtual - options.stack_size * std.mem.page_size),
          [stack_address] "{t1}" (max_virtual),
          [main] "{t2}" (&root.main),
          [exit_id] "I" (@intFromEnum(syscall.Id.exit)),
    );
}
