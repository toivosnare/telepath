const std = @import("std");
const root = @import("root");
const options = @import("options");
const libt = @import("libt");
const syscall = libt.syscall;

comptime {
    if (options.include_entry_point)
        @export(_start, .{ .name = "_start" });
}

fn _start(a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize, a7: usize) callconv(.C) noreturn {
    var args_array: [7]usize = .{ a1, a2, a3, a4, a5, a6, a7 };
    const args: []usize = (&args_array)[0..a0];

    const bad_main_ret = "expected return type of main to be 'void', '!void', 'noreturn', 'usize', or '!usize'";
    const ReturnType = @typeInfo(@TypeOf(root.main)).Fn.return_type.?;
    const exit_code: usize = switch (@typeInfo(ReturnType)) {
        .NoReturn => root.main(args),
        .Void => blk: {
            root.main(args);
            break :blk 0;
        },
        .Int => blk: {
            if (ReturnType != usize)
                @compileError(bad_main_ret);
            break :blk root.main(args);
        },
        .ErrorUnion => blk: {
            const result = root.main(args) catch break :blk 1;
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
