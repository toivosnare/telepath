const std = @import("std");
const root = @import("root");
const options = @import("options");

pub const heap = @import("heap.zig");
pub const syscall = @import("syscall.zig");
pub const tix = @import("tix.zig");

pub const address_space_end = 0x4000000000;

comptime {
    if (options.include_entry_point)
        @export(_start, .{ .name = "_start" });
}

fn _start() callconv(.Naked) noreturn {
    // Allocate and map stack, jump to main.
    asm volatile (
        \\li a0, %[allocate_id]
        \\li a1, %[stack_size]
        \\li a2, %[stack_permissions]
        \\li a3, 0
        \\ecall
        \\bltz a0, 1f
        \\mv sp, %[stack_address]
        \\mul a2, a1, %[page_size]
        \\sub a2, sp, a2
        \\mv a1, a0
        \\li a0, %[map_id]
        \\ecall
        \\bltz a0, 1f
        \\jr %[call_main]
        \\1:
        \\li a0, %[exit_id]
        \\li a1, 1
        \\ecall
        :
        : [allocate_id] "I" (@intFromEnum(syscall.Id.allocate)),
          [stack_size] "I" (options.stack_size),
          [stack_permissions] "I" (syscall.Permissions{ .readable = true, .writable = true }),
          [stack_address] "{t1}" (address_space_end),
          [page_size] "{t2}" (std.mem.page_size),
          [map_id] "I" (@intFromEnum(syscall.Id.map)),
          [call_main] "{t3}" (@intFromPtr(&callMain)),
          [exit_id] "I" (@intFromEnum(syscall.Id.exit)),
    );
}

fn callMain() noreturn {
    const bad_main_ret = "expected return type of main to be 'void', '!void', 'noreturn', 'usize', or '!usize'";
    const ReturnType = @typeInfo(@TypeOf(root.main)).Fn.return_type.?;
    const exit_code: usize = switch (@typeInfo(ReturnType)) {
        .NoReturn => root.main(),
        .Void => blk: {
            root.main();
            break :blk 0;
        },
        .Int => blk: {
            if (ReturnType != usize)
                @compileError(bad_main_ret);
            break :blk root.main();
        },
        .ErrorUnion => blk: {
            const result = root.main() catch break :blk 1;
            const NormalType = @TypeOf(result);
            switch (@typeInfo(NormalType)) {
                .Void => break :blk 0,
                .Int => {
                    if (NormalType != usize)
                        @compileError(bad_main_ret);
                    break :blk result;
                },
                else => @compileError(bad_main_ret),
            }
        },
        else => @compileError(bad_main_ret),
    };
    syscall.exit(exit_code);
}
