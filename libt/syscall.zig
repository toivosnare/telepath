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

pub const Error = IdentifyError || ForkError || SpawnError || KillError || AllocateError || MapError || ShareError || RefcountError || UnmapError;

pub fn packResult(result: Error!usize) usize {
    if (result) |res| {
        return res;
    } else |err| {
        const signed: isize = switch (err) {
            error.OutOfMemory => -1,
            error.InvalidParameter => -2,
            error.NoPermission => -3,
            error.Reserved => -4,
            error.Exists => -5,
        };
        return @bitCast(signed);
    }
}

fn unpackResult(comptime E: type, a0: usize) E!usize {
    const signed: isize = @bitCast(a0);
    const result = switch (signed) {
        -1 => error.OutOfMemory,
        -2 => error.InvalidParameter,
        -3 => error.NoPermission,
        -4 => error.Reserved,
        -5 => error.Exists,
        else => a0,
    };
    return @errorCast(result);
}

pub fn exit(exit_code: usize) noreturn {
    _ = syscall1(.exit, exit_code);
    unreachable;
}

pub const IdentifyError = error{};
pub fn identify() IdentifyError!usize {
    return unpackResult(IdentifyError, syscall0(.identify));
}

pub const ForkError = error{OutOfMemory};
pub fn fork() ForkError!usize {
    return unpackResult(ForkError, syscall0(.fork));
}

pub const SpawnError = error{ InvalidParameter, NoPermission, OutOfMemory, Reserved };
pub fn spawn(region_descriptions: []const RegionDescription, entry_point: usize) IdentifyError!usize {
    return unpackResult(syscall3(.spawn, region_descriptions.len, @intFromPtr(region_descriptions.ptr), entry_point));
}

pub const KillError = error{NoPermission};
pub fn kill(pid: usize) KillError!void {
    unpackResult(syscall1(.kill, pid)) catch |err| return err;
}

pub const AllocateError = error{ OutOfMemory, InvalidParameter };
pub fn allocate(size: usize, permissions: Permissions, physical_address: usize) AllocateError!usize {
    return unpackResult(AllocateError, syscall3(.allocate, size, @bitCast(permissions), physical_address));
}

pub const MapError = error{ InvalidParameter, Reserved, NoPermission, Exists };
pub fn map(region: usize, virtual_address: usize) MapError!usize {
    return unpackResult(MapError, syscall2(.map, region, virtual_address));
}

pub const ShareError = error{ InvalidParameter, NoPermission, OutOfMemory };
pub fn share(region: usize, pid: usize, permissions: Permissions) ShareError!void {
    unpackResult(syscall3(.share, region, pid, @bitCast(permissions))) catch |err| return err;
}

pub const RefcountError = error{ InvalidParameter, NoPermission };
pub fn refcount(region: usize) RefcountError!usize {
    return unpackResult(syscall1(.refcount, region));
}

pub const UnmapError = error{InvalidParameter};
pub fn unmap(region: usize) UnmapError!void {
    unpackResult(syscall1(.unmap, region)) catch |err| return err;
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

inline fn syscall0(id: Id) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [id] "{a0}" (@intFromEnum(id)),
        : "memory"
    );
}

inline fn syscall1(id: Id, arg1: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [id] "{a0}" (@intFromEnum(id)),
          [arg1] "{a1}" (arg1),
        : "memory"
    );
}

inline fn syscall2(id: Id, arg1: usize, arg2: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [id] "{a0}" (@intFromEnum(id)),
          [arg1] "{a1}" (arg1),
          [arg2] "{a2}" (arg2),
        : "memory"
    );
}

inline fn syscall3(id: Id, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [id] "{a0}" (@intFromEnum(id)),
          [arg1] "{a1}" (arg1),
          [arg2] "{a2}" (arg2),
          [arg3] "{a3}" (arg3),
        : "memory"
    );
}
