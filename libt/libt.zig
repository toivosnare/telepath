pub const tix = @import("tix.zig");

pub const SyscallId = enum(usize) {
    exit = 0,
    get_pid = 1,
};
