pub const heap = @import("heap.zig");
pub const service = @import("service.zig");
pub const start = @import("start.zig");
pub const syscall = @import("syscall.zig");
pub const tix = @import("tix.zig");

pub const address_space_end = 0x4000000000;

comptime {
    _ = start;
}
