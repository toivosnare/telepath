pub const tix = @import("tix.zig");

pub const SyscallId = enum(usize) {
    exit = 0,
    identify = 1,
    fork = 2,
    spawn = 3,
    kill = 4,
    allocate = 5,
    map = 6,
    share = 7,
    refcount = 8,
    unmap = 9,
    wait = 10,
    wake = 11,
};

pub const RegionDescription = packed struct {
    region_index: u16,
    start_address: usize,
    readable: bool,
    writable: bool,
    executable: bool,
};

pub const AllocatePermissions = packed struct(u3) {
    readable: bool,
    writable: bool,
    executable: bool,
};
