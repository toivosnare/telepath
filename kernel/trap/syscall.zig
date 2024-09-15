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
    const hart_index = process.context.hart_index;

    proc.checkWaitChildProcess(process, exit_code);
    proc.free(process);
    proc.scheduleNext(null, hart_index);
}

pub const IdentifyError = libt.syscall.IdentifyError;
pub fn identify(process: *Process) IdentifyError!usize {
    return process.id;
}

pub const ForkError = libt.syscall.ForkError;
pub fn fork(process: *Process) ForkError!usize {
    log.debug("Process with ID {d} is forking.", .{process.id});

    const child_process = try proc.allocate();
    errdefer proc.free(child_process);

    process.children.append(child_process) catch return error.OutOfMemory;
    child_process.parent = process;

    // TODO: copy region entries properly.
    child_process.region_entries_head = process.region_entries_head;

    @memcpy(
        mem.asBytes(&child_process.context),
        mem.asBytes(&process.context),
    );
    child_process.context.a0 = process.id;
    return child_process.id;
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

    const child_process = try proc.allocate();
    errdefer proc.free(child_process);

    process.children.append(child_process) catch return error.OutOfMemory;
    child_process.parent = process;

    for (region_descriptions) |region_description| {
        const region = Region.fromIndex(region_description.region) catch unreachable;
        const region_entry = try child_process.receiveRegion(region, .{
            .readable = region_description.readable,
            .writable = region_description.writable,
            .executable = region_description.executable,
        });
        if (region_description.start_address != null)
            _ = try child_process.mapRegionEntry(region_entry, @intFromPtr(region_description.start_address));
    }

    child_process.context.a0 = argument_amount;
    const registers: [*]usize = @ptrCast(&child_process.context.a1);
    for (arguments, registers) |arg, *reg|
        reg.* = arg;

    child_process.context.pc = instruction_pointer;
    child_process.context.sp = stack_pointer;
    return child_process.id;
}

pub const KillError = libt.syscall.KillError;
pub fn kill(process: *Process) KillError!usize {
    const child_pid = process.context.a1;
    log.debug("Process with ID {d} is killing child with ID {d}.", .{ process.id, child_pid });

    const child_process = process.hasChildWithId(child_pid) orelse return error.NoPermission;
    proc.free(child_process);
    return 0;
}

pub const AllocateError = libt.syscall.AllocateError;
pub fn allocate(process: *Process) AllocateError!usize {
    const size = process.context.a1;
    const permissions: libt.syscall.Permissions = @bitCast(process.context.a2);
    const physical_address = process.context.a3;
    log.debug("Process with ID {d} is allocating region of size {d} with permissions {} at physical address 0x{x}.", .{ process.id, size, permissions, physical_address });

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
    const region_entry = process.hasRegion(region) orelse return error.NoPermission;
    if (permissions.readable and !region_entry.permissions.readable)
        return error.NoPermission;
    if (permissions.writable and !region_entry.permissions.writable)
        return error.NoPermission;
    if (permissions.executable and !region_entry.permissions.executable)
        return error.NoPermission;

    const recipient = proc.processFromId(recipient_id) orelse return error.InvalidParameter;
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
    _ = process.hasRegion(region) orelse return error.NoPermission;
    return region.ref_count;
}

pub const UnmapError = libt.syscall.UnmapError;
pub fn unmap(process: *Process) UnmapError!usize {
    const address = process.context.a1;
    log.debug("Process with ID {d} is unmapping region at address {d}.", .{ process.id, address });

    const region_entry = process.hasRegionAtAddress(address) orelse return error.InvalidParameter;
    try process.unmapRegionEntry(region_entry);
    return region_entry.region.?.index();
}

pub const FreeError = libt.syscall.FreeError;
pub fn free(process: *Process) FreeError!usize {
    const region_index = process.context.a1;
    log.debug("Process with ID {d} is freeing region {d}.", .{ process.id, region_index });

    const region = try Region.fromIndex(region_index);
    const region_entry = process.hasRegion(region) orelse return error.NoPermission;
    try process.freeRegionEntry(region_entry);
    return 0;
}

// TODO: Allow waiting on multiple.
// TODO: Allow waiting on interrupts.
pub const WaitError = libt.syscall.WaitError;
pub fn wait(process: *Process) WaitError!usize {
    const wait_reason_int = process.context.a1;
    const timeout_ns = process.context.a2;
    log.debug("Process with ID {d} is waiting.", .{process.id});

    if (wait_reason_int != 0) {
        const wait_reason: *const libt.syscall.WaitReason = @ptrFromInt(wait_reason_int);

        if (wait_reason.tag == .futex) {
            const virtual_address = @intFromPtr(wait_reason.payload.futex.address);
            const expected_value = wait_reason.payload.futex.expected_value;
            try proc.waitFutex(process, virtual_address, expected_value);
        } else if (wait_reason.tag == .child_process) {
            const child_pid = wait_reason.payload.child_process.pid;
            try proc.waitChildProcess(process, child_pid);
        } else {
            return error.InvalidParameter;
        }
    }

    if (timeout_ns != math.maxInt(usize))
        proc.waitTimeout(process, timeout_ns);
    proc.scheduleNext(null, process.context.hart_index);
}

pub const WakeError = libt.syscall.WakeError;
pub fn wake(process: *Process) WakeError!usize {
    const virtual_address = process.context.a1;
    const waiter_count = process.context.a2;
    log.debug("Process with ID {d} is waking {d} waiters waiting on address 0x{x}.", .{ process.id, waiter_count, virtual_address });

    if (virtual_address >= mm.user_virtual_end)
        return error.InvalidParameter;
    if (!mem.isAligned(virtual_address, @alignOf(u32)))
        return error.InvalidParameter;
    if (waiter_count == 0)
        return error.InvalidParameter;

    const physical_address = process.page_table.translate(virtual_address) catch return error.InvalidParameter;
    return proc.checkWaitFutex(physical_address, waiter_count);
}
