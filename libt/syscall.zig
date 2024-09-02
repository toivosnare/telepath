pub const Id = enum(usize) {
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

pub fn exit(exit_code: usize) noreturn {
    _ = syscall1(.exit, exit_code);
    unreachable;
}

pub fn identify() usize {
    return syscall0(.identify);
}

pub fn fork() usize {
    return syscall0(.fork);
}

pub fn spawn(region_descriptions: []const RegionDescription, entry_point: usize) usize {
    return syscall3(.spawn, region_descriptions.len, @intFromPtr(region_descriptions.ptr), entry_point);
}

pub fn kill(pid: usize) usize {
    return syscall1(.kill, pid);
}

pub fn allocate(size: usize, permissions: Permissions, physical_address: usize) usize {
    return syscall3(.allocate, size, @bitCast(permissions), physical_address);
}

pub fn map(region_index: usize, virtual_address: usize) usize {
    return syscall2(.map, region_index, virtual_address);
}

pub fn share(region_index: usize, pid: usize, permissions: Permissions) usize {
    return syscall3(.share, region_index, pid, @bitCast(permissions));
}

pub fn refcount(region_index: usize) usize {
    return syscall1(.refcount, region_index);
}

pub fn unmap(region_index: usize) usize {
    return syscall1(.unmap, region_index);
}

pub const RegionDescription = packed struct {
    region_index: u16,
    start_address: usize,
    readable: bool,
    writable: bool,
    executable: bool,
};

pub const Permissions = packed struct(u64) {
    executable: bool = false,
    writable: bool = false,
    readable: bool = false,
    padding: u61 = 0,
};

fn syscall0(id: Id) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [id] "{a0}" (@intFromEnum(id)),
        : "memory"
    );
}

fn syscall1(id: Id, arg1: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [id] "{a0}" (@intFromEnum(id)),
          [arg1] "{a1}" (arg1),
        : "memory"
    );
}

fn syscall2(id: Id, arg1: usize, arg2: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [id] "{a0}" (@intFromEnum(id)),
          [arg1] "{a1}" (arg1),
          [arg2] "{a2}" (arg2),
        : "memory"
    );
}

fn syscall3(id: Id, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [id] "{a0}" (@intFromEnum(id)),
          [arg1] "{a1}" (arg1),
          [arg2] "{a2}" (arg2),
          [arg3] "{a3}" (arg3),
        : "memory"
    );
}
