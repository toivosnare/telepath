const std = @import("std");
const log = std.log;
const assert = std.debug.assert;
const mem = std.mem;
const math = std.math;
const libt = @import("libt");
const proc = @import("../proc.zig");
const mm = @import("../mm.zig");
const Region = mm.Region;
const Process = proc.Process;

pub fn exit(process: *Process) noreturn {
    const exit_code = process.context.a1;
    log.debug("Process with PID {d} is exiting with exit code {d}.", .{ process.id, exit_code });

    process.lock.lock();
    process.exit(exit_code);
    proc.scheduler.scheduleNext(null, process.context.hart_index);
}

pub const IdentifyError = libt.syscall.IdentifyError;
pub fn identify(process: *Process) IdentifyError!usize {
    return process.id;
}

pub const ForkError = libt.syscall.ForkError;
pub fn fork(process: *Process) ForkError!usize {
    log.debug("Process with ID {d} is forking.", .{process.id});

    // const child_process = try proc.allocate();
    // errdefer proc.free(child_process);

    // process.children.append(child_process) catch return error.OutOfMemory;
    // child_process.parent = process;

    // // TODO: copy region entries properly.
    // child_process.region_entries_head = process.region_entries_head;

    // @memcpy(
    //     mem.asBytes(&child_process.context),
    //     mem.asBytes(&process.context),
    // );
    // child_process.context.a0 = process.id;
    // return child_process.id;
    return 0;
}

pub const SpawnError = libt.syscall.SpawnError;
pub fn spawn(process: *Process) SpawnError!usize {
    const region_amount = process.context.a1;
    if (region_amount == 0)
        return error.InvalidParameter;

    const region_descriptions_int = process.context.a2;
    if (region_descriptions_int == 0)
        return error.InvalidParameter;
    const region_descriptions_ptr: [*]libt.syscall.RegionDescription = @ptrFromInt(region_descriptions_int);
    const region_descriptions: []libt.syscall.RegionDescription = region_descriptions_ptr[0..region_amount];

    const argument_amount = process.context.a3;
    if (argument_amount > 7)
        return error.InvalidParameter;

    const arguments_int = process.context.a4;
    if (arguments_int == 0)
        return error.InvalidParameter;
    const arguments_ptr: [*]usize = @ptrFromInt(arguments_int);
    const arguments: []usize = arguments_ptr[0..region_amount];

    const instruction_pointer = process.context.a5;
    const stack_pointer = process.context.a6;
    log.debug("Process with ID {d} is spawning with {d} regions and {d} arguments.", .{ process.id, region_amount, argument_amount });

    {
        process.lock.lock();
        defer process.lock.unlock();

        for (region_descriptions) |region_description| {
            const region = try Region.fromIndex(region_description.region);
            if (region.isFree())
                return error.InvalidParameter;

            const region_entry = process.hasRegion(region) orelse return error.NoPermission;
            if (region_description.readable and !region_entry.permissions.readable)
                return error.NoPermission;
            if (region_description.writable and !region_entry.permissions.writable)
                return error.NoPermission;
            if (region_description.executable and !region_entry.permissions.executable)
                return error.NoPermission;
        }
        process.children.ensureUnusedCapacity(1) catch return error.OutOfMemory;
    }

    const child_process = try proc.allocate();
    {
        defer child_process.lock.unlock();
        errdefer proc.free(child_process);

        child_process.parent = process;

        for (region_descriptions) |region_description| {
            const region = Region.fromIndex(region_description.region) catch unreachable;
            const region_entry = child_process.receiveRegion(region, .{
                .readable = region_description.readable,
                .writable = region_description.writable,
                .executable = region_description.executable,
            }) catch unreachable;
            if (region_description.start_address != null)
                _ = try child_process.mapRegionEntry(region_entry, @intFromPtr(region_description.start_address));
        }

        child_process.context.a0 = argument_amount;
        const registers: [*]usize = @ptrCast(&child_process.context.a1);
        for (arguments, registers) |arg, *reg|
            reg.* = arg;
        child_process.context.pc = instruction_pointer;
        child_process.context.sp = stack_pointer;

        proc.scheduler.enqueue(child_process);
    }

    process.lock.lock();
    process.children.append(child_process) catch unreachable;
    process.lock.unlock();

    return child_process.id;
}

pub const KillError = libt.syscall.KillError;
pub fn kill(process: *Process) KillError!usize {
    const child_pid = process.context.a1;
    log.debug("Process with ID {d} is killing child with ID {d}.", .{ process.id, child_pid });

    process.lock.lock();
    defer process.lock.unlock();

    const child_process = process.hasChildWithId(child_pid) orelse return error.NoPermission;
    process.kill(child_process);

    return 0;
}

pub const AllocateError = libt.syscall.AllocateError;
pub fn allocate(process: *Process) AllocateError!usize {
    const size = process.context.a1;
    const permissions: libt.syscall.Permissions = @bitCast(process.context.a2);
    const physical_address = process.context.a3;
    log.debug("Process with ID {d} is allocating region of size {d} with permissions {} at physical address 0x{x}.", .{ process.id, size, permissions, physical_address });

    process.lock.lock();
    defer process.lock.unlock();

    const region_entry = try process.allocateRegion(size, .{
        .readable = permissions.readable,
        .writable = permissions.writable,
        .executable = permissions.executable,
    }, physical_address);
    assert(region_entry.region != null);
    return region_entry.region.?.index();
}

pub const MapError = libt.syscall.MapError;
pub fn map(process: *Process) MapError!usize {
    const region_index = process.context.a1;
    const requested_address = process.context.a2;
    log.debug("Process with ID {d} is mapping region {d} at 0x{x}.", .{ process.id, region_index, requested_address });

    const region = try Region.fromIndex(region_index);

    process.lock.lock();
    defer process.lock.unlock();

    const actual_address = try process.mapRegion(region, requested_address);
    return actual_address;
}

pub const ShareError = libt.syscall.ShareError;
pub fn share(process: *Process) ShareError!usize {
    const region_index = process.context.a1;
    const recipient_id = process.context.a2;
    const permissions: libt.syscall.Permissions = @bitCast(process.context.a3);
    log.debug("Process with ID {d} is sharing region {d} with process with ID {d} with permissions: {}.", .{ process.id, region_index, recipient_id, permissions });

    const region = try Region.fromIndex(region_index);

    {
        process.lock.lock();
        defer process.lock.unlock();

        const region_entry = process.hasRegion(region) orelse return error.NoPermission;
        if (permissions.readable and !region_entry.permissions.readable)
            return error.NoPermission;
        if (permissions.writable and !region_entry.permissions.writable)
            return error.NoPermission;
        if (permissions.executable and !region_entry.permissions.executable)
            return error.NoPermission;
    }

    const recipient = proc.processFromId(recipient_id) orelse return error.InvalidParameter;
    defer recipient.lock.unlock();

    _ = try recipient.receiveRegion(region, .{
        .readable = permissions.readable,
        .writable = permissions.writable,
        .executable = permissions.executable,
    });
    return 0;
}

pub const RefcountError = libt.syscall.RefcountError;
pub fn refcount(process: *Process) RefcountError!usize {
    const region_index = process.context.a1;
    log.debug("Process with ID {d} is getting the reference count of the region {d}.", .{ process.id, region_index });

    const region = try Region.fromIndex(region_index);

    {
        process.lock.lock();
        defer process.lock.unlock();
        _ = process.hasRegion(region) orelse return error.NoPermission;
    }

    return region.refCount();
}

pub const UnmapError = libt.syscall.UnmapError;
pub fn unmap(process: *Process) UnmapError!usize {
    const address = process.context.a1;
    log.debug("Process with ID {d} is unmapping region at address {d}.", .{ process.id, address });

    process.lock.lock();
    defer process.lock.unlock();

    const region_entry = process.hasRegionAtAddress(address) orelse return error.InvalidParameter;
    try process.unmapRegionEntry(region_entry);
    return region_entry.region.?.index();
}

pub const FreeError = libt.syscall.FreeError;
pub fn free(process: *Process) FreeError!usize {
    const region_index = process.context.a1;
    log.debug("Process with ID {d} is freeing region {d}.", .{ process.id, region_index });

    const region = try Region.fromIndex(region_index);

    process.lock.lock();
    defer process.lock.unlock();

    const region_entry = process.hasRegion(region) orelse return error.NoPermission;
    try process.freeRegionEntry(region_entry);
    return 0;
}

// TODO: Allow waiting on interrupts.
pub const WaitError = libt.syscall.WaitError;
pub fn wait(process: *Process) WaitError!usize {
    const reasons_count = process.context.a1;
    const reasons_int = process.context.a2;
    log.debug("Process with ID {d} is waiting.", .{process.id});

    assert(process.wait_reason_count == 0);

    process.lock.lock();
    {
        defer process.lock.unlock();
        if (reasons_count != 0 and reasons_int != 0) {
            const reasons_start: [*]libt.syscall.WaitReason = @ptrFromInt(reasons_int);
            const reasons: []libt.syscall.WaitReason = reasons_start[0..reasons_count];

            for (0.., reasons) |index, *reason| {
                process.wait(reason) catch |err| {
                    reason.result = libt.syscall.packResult(err);
                    process.waitClear();
                    return index;
                };
            }
            process.wait_reasons_user = reasons;
            process.wait_all = process.context.a3 != 0;
        }

        const timeout_ns = process.context.a4;
        proc.timeout.wait(process, timeout_ns);
        process.state = .waiting;
    }

    proc.scheduler.scheduleNext(null, process.context.hart_index);
}

pub const WakeError = libt.syscall.WakeError;
pub fn wake(process: *Process) WakeError!usize {
    const virtual_address = process.context.a1;
    const waiter_count = process.context.a2;
    log.debug("Process with ID {d} is waking {d} waiters waiting on address 0x{x}.", .{ process.id, waiter_count, virtual_address });

    return proc.futex.wake(process, virtual_address, waiter_count);
}
