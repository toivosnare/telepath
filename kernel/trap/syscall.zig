const std = @import("std");
const log = std.log.scoped(.@"trap.syscall");
const math = std.math;
const libt = @import("libt");
const syscall = libt.syscall;
const Handle = libt.Handle;
const proc = @import("../proc.zig");
const Process = proc.Process;
const Thread = proc.Thread;
const Capability = proc.Capability;

pub const ProcessAllocateError = syscall.ProcessAllocateError;
pub fn processAllocate(thread: *Thread) ProcessAllocateError!usize {
    log.debug("processAllocate", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    return usizeFromHandle(try owner_process.allocateProcess());
}

pub const ProcessFreeError = syscall.ProcessFreeError;
pub fn processFree(thread: *Thread) ProcessFreeError!usize {
    log.debug("processFree", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const target_process_handle = handleFromUsize(thread.context.a2);
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    try owner_process.freeProcess(target_process_handle);
    return 0;
}

pub const ProcessShareError = syscall.ProcessShareError;
pub fn processShare(thread: *Thread) ProcessShareError!usize {
    log.debug("processShare", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const target_process_handle = handleFromUsize(thread.context.a2);
    const recipient_process_handle = handleFromUsize(thread.context.a3);
    const permissions: libt.syscall.ProcessPermissions = @bitCast(thread.context.a4);
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    const recipient_process = try getProcess(calling_process, recipient_process_handle);
    return usizeFromHandle(try owner_process.shareProcess(target_process_handle, recipient_process, permissions));
}

pub const ProcessTranslateError = syscall.ProcessTranslateError;
pub fn processTranslate(thread: *Thread) ProcessTranslateError!usize {
    log.debug("processTranslate", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const virtual_address = thread.context.a2;
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    return owner_process.translate(virtual_address);
}

pub const RegionAllocateError = syscall.RegionAllocateError;
pub fn regionAllocate(thread: *Thread) RegionAllocateError!usize {
    log.debug("regionAllocate", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const size = thread.context.a2;
    const permissions: libt.syscall.RegionPermissions = @bitCast(thread.context.a3);
    const physical_address = thread.context.a4;
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    return usizeFromHandle(try owner_process.allocateRegion(size, permissions, physical_address));
}

pub const RegionFreeError = syscall.RegionFreeError;
pub fn regionFree(thread: *Thread) RegionFreeError!usize {
    log.debug("regionFree", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const target_region_handle = handleFromUsize(thread.context.a2);
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    try owner_process.freeRegion(target_region_handle);
    return 0;
}

pub const RegionShareError = syscall.RegionShareError;
pub fn regionShare(thread: *Thread) RegionShareError!usize {
    log.debug("regionShare", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const target_region_handle = handleFromUsize(thread.context.a2);
    const recipient_process_handle = handleFromUsize(thread.context.a3);
    const permissions: libt.syscall.RegionPermissions = @bitCast(thread.context.a4);
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    const recipient_process = try getProcess(calling_process, recipient_process_handle);
    return usizeFromHandle(try owner_process.shareRegion(target_region_handle, recipient_process, permissions));
}

pub const RegionMapError = syscall.RegionMapError;
pub fn regionMap(thread: *Thread) RegionMapError!usize {
    log.debug("regionMap", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const target_region_handle = handleFromUsize(thread.context.a2);
    const virtual_address = thread.context.a3;
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    return owner_process.mapRegion(target_region_handle, virtual_address);
}

pub const RegionUnmapError = syscall.RegionUnmapError;
pub fn regionUnmap(thread: *Thread) RegionUnmapError!usize {
    log.debug("regionUnmap", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const virtual_address = thread.context.a2;
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    return usizeFromHandle(try owner_process.unmapRegion(virtual_address));
}

pub const RegionReadError = syscall.RegionReadError;
pub fn regionRead(thread: *Thread) RegionReadError!usize {
    log.debug("regionRead", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const target_region_handle = handleFromUsize(thread.context.a2);
    const to = thread.context.a3;
    const offset = thread.context.a4;
    const length = thread.context.a5;
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    try owner_process.readRegion(target_region_handle, to, offset, length);
    return 0;
}

pub const RegionWriteError = syscall.RegionWriteError;
pub fn regionWrite(thread: *Thread) RegionWriteError!usize {
    log.debug("regionWrite", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const target_region_handle = handleFromUsize(thread.context.a2);
    const from = thread.context.a3;
    const offset = thread.context.a4;
    const length = thread.context.a5;
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    try owner_process.writeRegion(target_region_handle, from, offset, length);
    return 0;
}

pub const RegionRefCountError = syscall.RegionRefCountError;
pub fn regionRefCount(thread: *Thread) RegionRefCountError!usize {
    log.debug("regionRefCount", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const target_region_handle = handleFromUsize(thread.context.a2);
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    return owner_process.refCountRegion(target_region_handle);
}

pub const RegionSizeError = syscall.RegionSizeError;
pub fn regionSize(thread: *Thread) RegionSizeError!usize {
    log.debug("regionSize", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const target_region_handle = handleFromUsize(thread.context.a2);
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    return owner_process.sizeRegion(target_region_handle);
}

pub const ThreadAllocateError = syscall.ThreadAllocateError;
pub fn threadAllocate(thread: *Thread) ThreadAllocateError!usize {
    log.debug("threadAllocate", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const target_process_handle = handleFromUsize(thread.context.a2);
    const instruction_pointer = thread.context.a3;
    const stack_pointer = thread.context.a4;
    const a0 = thread.context.a5;
    const a1 = thread.context.a6;
    const a2 = thread.context.a7;
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    return usizeFromHandle(try owner_process.allocateThread(target_process_handle, instruction_pointer, stack_pointer, a0, a1, a2));
}

pub const ThreadFreeError = syscall.ThreadFreeError;
pub fn threadFree(thread: *Thread) ThreadFreeError!usize {
    log.debug("threadFree", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const target_process_handle = handleFromUsize(thread.context.a2);
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    try owner_process.freeThread(target_process_handle);
    return 0;
}

pub const ThreadShareError = syscall.ThreadShareError;
pub fn threadShare(thread: *Thread) ThreadShareError!usize {
    log.debug("threadShare", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const target_thread_handle = handleFromUsize(thread.context.a2);
    const recipient_process_handle = handleFromUsize(thread.context.a3);
    const permissions: libt.syscall.ThreadPermissions = @bitCast(thread.context.a4);
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    const recipient_process = try getProcess(calling_process, recipient_process_handle);
    return usizeFromHandle(try owner_process.shareThread(target_thread_handle, recipient_process, permissions));
}

pub const ThreadKillError = syscall.ThreadKillError;
pub fn threadKill(thread: *Thread) ThreadKillError!usize {
    log.debug("threadKill", .{});
    const owner_process_handle = handleFromUsize(thread.context.a1);
    const target_thread_handle = handleFromUsize(thread.context.a2);
    const exit_code = thread.context.a3;
    const calling_process = thread.process;

    const owner_process = try getProcess(calling_process, owner_process_handle);
    try owner_process.killThread(target_thread_handle, exit_code);
    return 0;
}

pub fn exit(thread: *Thread) noreturn {
    log.debug("exit", .{});
    const exit_code = thread.context.a1;
    const hart_index = thread.context.hart_index;
    thread.exit(exit_code);
    thread.lock.unlock();
    proc.scheduler.scheduleNext(null, hart_index);
}

pub const SynchronizeError = syscall.SynchronizeError;
pub fn synchronize(thread: *Thread) SynchronizeError!usize {
    log.debug("synchronize", .{});
    const signals_count = thread.context.a1;
    const signals_int = thread.context.a2;
    const events_count = thread.context.a3;
    const events_int = thread.context.a4;
    const timeout_us = thread.context.a5;

    const signals_start: ?[*]libt.syscall.WakeSignal = @ptrFromInt(signals_int);
    const signals: []libt.syscall.WakeSignal = if (signals_start) |start|
        start[0..signals_count]
    else
        &.{};

    const events_start: ?[*]libt.syscall.WaitEvent = @ptrFromInt(events_int);
    const events: []libt.syscall.WaitEvent = if (events_start) |start|
        start[0..events_count]
    else
        &.{};

    return thread.synchronize(signals, events, timeout_us);
}

pub const AckError = syscall.AckError;
pub fn ack(thread: *Thread) AckError!usize {
    log.debug("ack", .{});
    const source = math.cast(u32, thread.context.a1) orelse return error.InvalidParameter;
    thread.ack(source);
    return 0;
}

fn usizeFromHandle(handle: Handle) usize {
    return @intCast(@intFromEnum(handle));
}

fn handleFromUsize(@"usize": usize) Handle {
    return @enumFromInt(@"usize");
}

fn getProcess(owner_process: *Process, process_handle: Handle) !*Process {
    owner_process.lock.lock();
    defer owner_process.lock.unlock();

    const process_capability = try Capability.get(process_handle, owner_process);
    return process_capability.process(owner_process);
}
