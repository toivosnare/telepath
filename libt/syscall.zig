const std = @import("std");
const atomic = std.atomic;
const page_size = std.heap.pageSize();
const libt = @import("root.zig");
const Handle = libt.Handle;

pub const Id = enum(usize) {
    process_allocate = 0,
    process_free = 1,
    process_share = 2,
    process_translate = 3,
    region_allocate = 4,
    region_free = 5,
    region_share = 6,
    region_map = 7,
    region_unmap = 8,
    region_read = 9,
    region_write = 10,
    region_ref_count = 11,
    region_size = 12,
    thread_allocate = 13,
    thread_free = 14,
    thread_share = 15,
    thread_kill = 16,
    exit = 17,
    synchronize = 18,
    ack = 19,
};

pub const count = @typeInfo(Id).Enum.fields.len;

pub const ProcessAllocateError = error{ InvalidParameter, NoPermission, InvalidType, OutOfMemory };
pub fn processAllocate(owner_process: Handle) ProcessAllocateError!Handle {
    return unpackResult(ProcessAllocateError!Handle, syscall1(.process_allocate, @intFromEnum(owner_process)));
}

pub const ProcessFreeError = error{ InvalidParameter, NoPermission, InvalidType };
pub fn processFree(owner_process: Handle, target_process: Handle) ProcessFreeError!void {
    return unpackResult(ProcessFreeError!void, syscall2(.process_free, @intFromEnum(owner_process), @intFromEnum(target_process)));
}

pub const ProcessShareError = error{ InvalidParameter, NoPermission, InvalidType, OutOfMemory };
pub fn processShare(owner_process: Handle, target_process: Handle, recipient_process: Handle, permissions: ProcessPermissions) ProcessShareError!Handle {
    return unpackResult(ProcessShareError!Handle, syscall4(.process_share, @intFromEnum(owner_process), @intFromEnum(target_process), @intFromEnum(recipient_process), @bitCast(permissions)));
}

pub const ProcessTranslateError = error{ InvalidParameter, NoPermission, InvalidType, NotMapped };
pub fn processTranslate(owner_process: Handle, virtual_address: *const anyopaque) ProcessTranslateError!*anyopaque {
    return unpackResult(ProcessTranslateError!*anyopaque, syscall2(.process_translate, @intFromEnum(owner_process), @intFromPtr(virtual_address)));
}

pub const RegionAllocateError = error{ InvalidParameter, NoPermission, InvalidType, OutOfMemory };
pub fn regionAllocate(owner_process: Handle, length: usize, permissions: RegionPermissions, physical_address: ?*const anyopaque) RegionAllocateError!Handle {
    return unpackResult(RegionAllocateError!Handle, syscall4(.region_allocate, @intFromEnum(owner_process), length, @bitCast(permissions), @intFromPtr(physical_address)));
}

pub const RegionFreeError = error{ InvalidParameter, NoPermission, InvalidType, Mapped };
pub fn regionFree(owner_process: Handle, target_region: Handle) RegionFreeError!void {
    return unpackResult(RegionFreeError!void, syscall2(.region_free, @intFromEnum(owner_process), @intFromEnum(target_region)));
}

pub const RegionShareError = error{ InvalidParameter, NoPermission, InvalidType, OutOfMemory };
pub fn regionShare(owner_process: Handle, target_region: Handle, recipient_process: Handle, permissions: RegionPermissions) RegionShareError!Handle {
    return unpackResult(RegionShareError!Handle, syscall4(.region_share, @intFromEnum(owner_process), @intFromEnum(target_region), @intFromEnum(recipient_process), @bitCast(permissions)));
}

pub const RegionMapError = error{ InvalidParameter, NoPermission, InvalidType, Mapped, Reserved };
pub fn regionMap(owner_process: Handle, target_region: Handle, virtual_address: ?*align(page_size) anyopaque) RegionMapError!*align(page_size) anyopaque {
    return unpackResult(RegionMapError!*align(page_size) anyopaque, syscall3(.region_map, @intFromEnum(owner_process), @intFromEnum(target_region), @intFromPtr(virtual_address)));
}

pub const RegionUnmapError = error{ InvalidParameter, NoPermission, InvalidType };
pub fn regionUnmap(owner_process: Handle, virtual_address: *align(page_size) anyopaque) RegionUnmapError!Handle {
    return unpackResult(RegionUnmapError!Handle, syscall2(.region_unmap, @intFromEnum(owner_process), @intFromPtr(virtual_address)));
}

pub const RegionReadError = error{ InvalidParameter, NoPermission, InvalidType };
pub fn regionRead(owner_process: Handle, target_region: Handle, to: *const anyopaque, offset: usize, length: usize) RegionReadError!void {
    return unpackResult(RegionReadError!void, syscall5(.region_read, @intFromEnum(owner_process), @intFromEnum(target_region), @intFromPtr(to), offset, length));
}

pub const RegionWriteError = error{ InvalidParameter, NoPermission, InvalidType };
pub fn regionWrite(owner_process: Handle, target_region: Handle, from: *const anyopaque, offset: usize, length: usize) RegionWriteError!void {
    return unpackResult(RegionWriteError!void, syscall5(.region_write, @intFromEnum(owner_process), @intFromEnum(target_region), @intFromPtr(from), offset, length));
}

pub const RegionRefCountError = error{ InvalidParameter, NoPermission, InvalidType };
pub fn regionRefCount(owner_process: Handle, target_region: Handle) RegionRefCountError!usize {
    return unpackResult(RegionRefCountError!usize, syscall2(.region_ref_count, @intFromEnum(owner_process), @intFromEnum(target_region)));
}

pub const RegionSizeError = error{ InvalidParameter, NoPermission, InvalidType };
pub fn regionSize(owner_process: Handle, target_region: Handle) RegionSizeError!usize {
    return unpackResult(RegionSizeError!usize, syscall2(.region_size, @intFromEnum(owner_process), @intFromEnum(target_region)));
}

pub const ThreadAllocateError = error{ InvalidParameter, NoPermission, InvalidType, OutOfMemory };
pub fn threadAllocate(owner_process: Handle, target_process: Handle, instruction_pointer: *const anyopaque, stack_pointer: *anyopaque, priority: usize, a0: usize, a1: usize) ThreadAllocateError!Handle {
    return unpackResult(ThreadAllocateError!Handle, syscall7(.thread_allocate, @intFromEnum(owner_process), @intFromEnum(target_process), @intFromPtr(instruction_pointer), @intFromPtr(stack_pointer), priority, a0, a1));
}

pub const ThreadFreeError = error{ InvalidParameter, NoPermission, InvalidType };
pub fn threadFree(owner_process: Handle, target_thread: Handle) ThreadFreeError!void {
    return unpackResult(ThreadFreeError!void, syscall2(.thread_free, owner_process, target_thread));
}

pub const ThreadShareError = error{ InvalidParameter, NoPermission, InvalidType, OutOfMemory };
pub fn threadShare(owner_process: Handle, target_thread: Handle, recipient_process: Handle, permissions: ThreadPermissions) ThreadShareError!Handle {
    return unpackResult(ThreadShareError!Handle, syscall4(.thread_share, owner_process, target_thread, recipient_process, @bitCast(permissions)));
}

pub const ThreadKillError = error{ InvalidParameter, NoPermission, InvalidType };
pub fn threadKill(owner_process: Handle, target_thread: Handle, exit_code: usize) ThreadKillError!void {
    return unpackResult(ThreadKillError!void, syscall3(.thread_kill, owner_process, target_thread, exit_code));
}

pub fn exit(exit_code: usize) noreturn {
    _ = syscall1(.exit, exit_code);
    unreachable;
}

pub const SynchronizeError = error{ InvalidParameter, OutOfMemory, NoPermission, Timeout, WouldBlock };
pub fn synchronize(signals: ?[]const WakeSignal, events: ?[]WaitEvent, timeout_us: usize) SynchronizeError!usize {
    const signals_len, const signals_ptr = if (signals) |s|
        .{ s.len, @intFromPtr(s.ptr) }
    else
        .{ 0, 0 };
    const events_len, const events_ptr = if (events) |r|
        .{ r.len, @intFromPtr(r.ptr) }
    else
        .{ 0, 0 };
    return unpackResult(SynchronizeError!usize, syscall5(.synchronize, signals_len, signals_ptr, events_len, events_ptr, timeout_us));
}

pub const AckError = error{InvalidParameter};
pub fn ack(source: u32) AckError!void {
    return unpackResult(AckError!void, syscall1(.ack, source));
}

pub const ProcessPermissions = packed struct(u64) {
    share: bool = false,
    padding: u63 = 0,
};

pub const RegionPermissions = packed struct(u64) {
    execute: bool = false,
    write: bool = false,
    read: bool = false,
    padding: u61 = 0,
};

pub const ThreadPermissions = packed struct(u64) {
    wait: bool = false,
    kill: bool = false,
    padding: u62 = 0,
};

pub const WakeSignal = extern struct {
    address: *const atomic.Value(u32),
    count: usize,
};

pub const WaitEvent = extern struct {
    payload: extern union {
        futex: Futex,
        thread: Handle,
        interrupt: u32,
    },
    result: usize = undefined,
    tag: Tag,

    pub const Futex = extern struct {
        address: *const atomic.Value(u32),
        expected_value: u32,
    };
    pub const Tag = enum(u8) {
        futex,
        thread,
        interrupt,
    };
};

// zig fmt: off
pub const Error = ProcessAllocateError
    || ProcessFreeError
    || ProcessShareError
    || ProcessTranslateError
    || RegionAllocateError
    || RegionFreeError
    || RegionShareError
    || RegionMapError
    || RegionUnmapError
    || RegionReadError
    || RegionWriteError
    || RegionRefCountError
    || RegionSizeError
    || ThreadAllocateError
    || ThreadFreeError
    || ThreadShareError
    || ThreadKillError
    || SynchronizeError
    || AckError
    || error{ Crashed, InvalidParameter };
// zig fmt: on

pub fn packResult(result: Error!usize) usize {
    if (result) |res| {
        return res;
    } else |err| {
        const signed: isize = switch (err) {
            error.InvalidParameter => -1,
            error.Crashed => -2,
            error.Timeout => -3,
            error.OutOfMemory => -4,
            error.NotMapped => -5,
            error.NoPermission => -6,
            error.InvalidType => -7,
            error.Mapped => -8,
            error.Reserved => -9,
            error.WouldBlock => -10,
        };
        return @bitCast(signed);
    }
}

pub fn unpackResult(comptime T: type, a0: usize) T {
    const type_info = @typeInfo(T);
    if (type_info != .error_union)
        @compileError("T must be an error union");

    // const E = type_info.error_union.error_set;
    const P = type_info.error_union.payload;

    const signed: isize = @bitCast(a0);
    const result: Error!P = switch (signed) {
        -1 => error.InvalidParameter,
        -2 => error.Crashed,
        -3 => error.Timeout,
        -4 => error.OutOfMemory,
        -5 => error.NotMapped,
        -6 => error.NoPermission,
        -7 => error.InvalidType,
        -8 => error.Mapped,
        -9 => error.Reserved,
        -10 => error.WouldBlock,
        else => switch (@typeInfo(P)) {
            .@"enum" => @as(P, @enumFromInt(a0)),
            .void => {},
            .pointer => @as(P, @ptrFromInt(a0)),
            .int => a0,
            else => @compileError("unsupported payload type"),
        },
    };
    return @errorCast(result);
}

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

inline fn syscall5(id: Id, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [id] "{a0}" (@intFromEnum(id)),
          [arg1] "{a1}" (arg1),
          [arg2] "{a2}" (arg2),
          [arg3] "{a3}" (arg3),
          [arg4] "{a4}" (arg4),
          [arg5] "{a5}" (arg5),
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

inline fn syscall7(id: Id, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize, arg7: usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [id] "{a0}" (@intFromEnum(id)),
          [arg1] "{a1}" (arg1),
          [arg2] "{a2}" (arg2),
          [arg3] "{a3}" (arg3),
          [arg4] "{a4}" (arg4),
          [arg5] "{a5}" (arg5),
          [arg6] "{a6}" (arg6),
          [arg7] "{a7}" (arg7),
        : "memory"
    );
}
