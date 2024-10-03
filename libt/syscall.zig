const std = @import("std");
const atomic = std.atomic;
const page_size = std.mem.page_size;

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
    free = 10,
    wait = 11,
    wake = 12,
};

pub const Error = IdentifyError || ForkError || SpawnError || KillError || AllocateError || MapError || ShareError || RefcountError || UnmapError || WaitError || WakeError;

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
            error.WouldBlock => -6,
            error.Timeout => -7,
            error.Crashed => -8,
        };
        return @bitCast(signed);
    }
}

pub fn unpackResult(comptime E: type, a0: usize) E!usize {
    const signed: isize = @bitCast(a0);
    const result = switch (signed) {
        -1 => error.OutOfMemory,
        -2 => error.InvalidParameter,
        -3 => error.NoPermission,
        -4 => error.Reserved,
        -5 => error.Exists,
        -6 => error.WouldBlock,
        -7 => error.Timeout,
        -8 => error.Crashed,
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
pub fn spawn(
    region_descriptions: []const RegionDescription,
    arguments: []const usize,
    instruction_pointer: *anyopaque,
    stack_pointer: *anyopaque,
) SpawnError!usize {
    return unpackResult(SpawnError, syscall6(
        .spawn,
        region_descriptions.len,
        @intFromPtr(region_descriptions.ptr),
        arguments.len,
        @intFromPtr(arguments.ptr),
        @intFromPtr(instruction_pointer),
        @intFromPtr(stack_pointer),
    ));
}

pub const KillError = error{NoPermission};
pub fn kill(pid: usize) KillError!void {
    _ = unpackResult(KillError, syscall1(.kill, pid)) catch |err| return err;
}

pub const AllocateError = error{ OutOfMemory, InvalidParameter };
pub fn allocate(size: usize, permissions: Permissions, physical_address: ?[*]align(page_size) [page_size]u8) AllocateError!usize {
    return unpackResult(AllocateError, syscall3(.allocate, size, @bitCast(permissions), @intFromPtr(physical_address)));
}

pub const MapError = error{ InvalidParameter, Reserved, NoPermission, Exists };
pub fn map(region: usize, virtual_address: ?[*]align(page_size) [page_size]u8) MapError![*]align(page_size) [page_size]u8 {
    return if (unpackResult(MapError, syscall2(.map, region, @intFromPtr(virtual_address)))) |addr|
        @ptrFromInt(addr)
    else |err|
        err;
}

pub const ShareError = error{ InvalidParameter, NoPermission, OutOfMemory };
pub fn share(region: usize, pid: usize, permissions: Permissions) ShareError!void {
    _ = unpackResult(ShareError, syscall3(.share, region, pid, @bitCast(permissions))) catch |err| return err;
}

pub const RefcountError = error{ InvalidParameter, NoPermission };
pub fn refcount(region: usize) RefcountError!usize {
    return unpackResult(RefcountError, syscall1(.refcount, region));
}

pub const UnmapError = error{ InvalidParameter, Exists };
pub fn unmap(address: [*]align(page_size) [page_size]u8) UnmapError!usize {
    return unpackResult(UnmapError, syscall1(.unmap, @intFromPtr(address)));
}

pub const FreeError = error{ InvalidParameter, NoPermission, Exists };
pub fn free(region: usize) FreeError!void {
    _ = unpackResult(FreeError, syscall1(.free, region)) catch |err| return err;
}

pub const WaitError = error{ InvalidParameter, WouldBlock, Timeout, NoPermission, Crashed };
pub fn wait(reasons: ?[]WaitReason, wait_all: bool, timeout_ns: usize) WaitError!usize {
    const count, const addr = if (reasons) |r|
        .{ r.len, @intFromPtr(r.ptr) }
    else
        .{ 0, 0 };
    return unpackResult(WaitError, syscall4(.wait, count, addr, @intFromBool(wait_all), timeout_ns));
}

pub const WakeError = error{InvalidParameter};
pub fn wake(address: *const atomic.Value(u32), waiter_count: usize) WakeError!usize {
    return unpackResult(WakeError, syscall2(.wake, @intFromPtr(address), waiter_count));
}

pub const RegionDescription = packed struct {
    region: usize,
    start_address: ?[*]align(page_size) [page_size]u8,
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

pub const WaitReason = extern struct {
    payload: extern union {
        futex: Futex,
        child_process: ChildProcess,
    },
    result: usize = undefined,
    tag: Tag,
    pub const Futex = extern struct {
        address: *const atomic.Value(u32),
        expected_value: u32,
    };
    pub const ChildProcess = extern struct {
        pid: usize,
    };
    pub const Tag = enum(u8) {
        futex,
        child_process,
    };
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

inline fn syscall4(id: Id, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [id] "{a0}" (@intFromEnum(id)),
          [arg1] "{a1}" (arg1),
          [arg2] "{a2}" (arg2),
          [arg3] "{a3}" (arg3),
          [arg4] "{a4}" (arg4),
        : "memory"
    );
}

inline fn syscall6(id: Id, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [id] "{a0}" (@intFromEnum(id)),
          [arg1] "{a1}" (arg1),
          [arg2] "{a2}" (arg2),
          [arg3] "{a3}" (arg3),
          [arg4] "{a4}" (arg4),
          [arg5] "{a5}" (arg5),
          [arg6] "{a6}" (arg6),
        : "memory"
    );
}
