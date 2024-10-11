const std = @import("std");
const log = std.log.scoped(.@"trap.syscall");
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
    log.debug("Process id={d} is exiting with exit code {d}", .{ process.id, exit_code });

    process.exit(exit_code);
    proc.scheduler.scheduleNext(null, process.context.hart_index);
}

pub const IdentifyError = libt.syscall.IdentifyError;
pub fn identify(process: *Process) IdentifyError!usize {
    log.debug("Process id={d} is identifying itself", .{process.id});
    return process.id;
}

pub const ForkError = libt.syscall.ForkError;
pub fn fork(process: *Process) ForkError!usize {
    log.debug("Process id={d} is forking", .{process.id});

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
    if (region_amount == 0) {
        log.warn("Process id={d} tried to spawn with 0 regions", .{process.id});
        return error.InvalidParameter;
    }

    const region_descriptions_int = process.context.a2;
    if (region_descriptions_int == 0) {
        log.warn("Process id={d} tried to spawn with null region descriptions pointer", .{process.id});
        return error.InvalidParameter;
    }
    const region_descriptions_ptr: [*]libt.syscall.RegionDescription = @ptrFromInt(region_descriptions_int);
    const region_descriptions: []libt.syscall.RegionDescription = region_descriptions_ptr[0..region_amount];

    const argument_amount = process.context.a3;
    if (argument_amount > 7) {
        log.warn("Process id={d} tried to spawn with {d} arguments", .{ process.id, argument_amount });
        return error.InvalidParameter;
    }

    const arguments_int = process.context.a4;
    if (arguments_int == 0) {
        log.warn("Process id={d} tried to spawn with null arguments pointer", .{process.id});
        return error.InvalidParameter;
    }
    const arguments_ptr: [*]usize = @ptrFromInt(arguments_int);
    const arguments: []usize = arguments_ptr[0..region_amount];

    const instruction_pointer = process.context.a5;
    const stack_pointer = process.context.a6;

    for (region_descriptions) |region_description| {
        const region = Region.fromIndex(region_description.region) catch |err| {
            log.warn("Process id={d} tried to spawn with Region with invalid index={d}", .{ process.id, region_description.region });
            return err;
        };
        if (region.isFree()) {
            log.warn("Process id={d} tried to spawn with free Region index={d}", .{ process.id, region_description.region });
            return error.InvalidParameter;
        }

        const region_entry = process.hasRegion(region) orelse {
            log.warn("Process id={d} tried to spawn with unowned Region index={d}", .{ process.id, region_description.region });
            return error.NoPermission;
        };
        if (region_description.readable and !region_entry.permissions.readable) {
            log.warn("Process id={d} tried to spawn with Region index={d} that it has no read permission for", .{ process.id, region_description.region });
            return error.NoPermission;
        }
        if (region_description.writable and !region_entry.permissions.writable) {
            log.warn("Process id={d} tried to spawn with Region index={d} that it has no write permission for", .{ process.id, region_description.region });
            return error.NoPermission;
        }
        if (region_description.executable and !region_entry.permissions.executable) {
            log.warn("Process id={d} tried to spawn with Region index={d} that it has no execute permission for", .{ process.id, region_description.region });
            return error.NoPermission;
        }
    }
    process.children.ensureUnusedCapacity(1) catch {
        log.warn("Process id={d} spawn failed because child array is full", .{process.id});
        return error.OutOfMemory;
    };

    log.debug("Process id={d} is spawning with {d} regions and {d} arguments, ip=0x{x}, sp=0x{x}", .{ process.id, region_amount, argument_amount, instruction_pointer, stack_pointer });

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

    process.children.append(child_process) catch unreachable;
    return child_process.id;
}

pub const KillError = libt.syscall.KillError;
pub fn kill(process: *Process) KillError!usize {
    const child_pid = process.context.a1;
    const child_process = process.hasChildWithId(child_pid) orelse {
        log.warn("Process id={d} tried to kill Process id={d} which is not a child", .{ process.id, child_pid });
        return error.NoPermission;
    };

    log.debug("Process id={d} is killing child Process id={d}", .{ process.id, child_pid });

    child_process.lock.lock();
    process.kill(child_process);
    child_process.lock.unlock();

    return 0;
}

pub const AllocateError = libt.syscall.AllocateError;
pub fn allocate(process: *Process) AllocateError!usize {
    const size = process.context.a1;
    const permissions: libt.syscall.Permissions = @bitCast(process.context.a2);
    const physical_address = process.context.a3;
    log.debug("Process id={d} is allocating Region size={d} permissions={} physical_address=0x{x}", .{ process.id, size, permissions, physical_address });

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

    const region = Region.fromIndex(region_index) catch |err| {
        log.warn("Process id={d} tried to map Region with invalid index={d}", .{ process.id, region_index });
        return err;
    };

    log.debug("Process id={d} is mapping Region index={d} address=0x{x}", .{ process.id, region_index, requested_address });

    const actual_address = try process.mapRegion(region, requested_address);
    return actual_address;
}

pub const ShareError = libt.syscall.ShareError;
pub fn share(process: *Process) ShareError!usize {
    const region_index = process.context.a1;
    const recipient_id = process.context.a2;
    const permissions: libt.syscall.Permissions = @bitCast(process.context.a3);

    const region = Region.fromIndex(region_index) catch |err| {
        log.warn("Process id={d} tried to share Region with invalid index={d}", .{ process.id, region_index });
        return err;
    };
    const region_entry = process.hasRegion(region) orelse {
        log.warn("Process id={d} tried to share unowned Region index={d}", .{ process.id, region_index });
        return error.NoPermission;
    };
    if (permissions.readable and !region_entry.permissions.readable) {
        log.warn("Process id={d} tried to share Region index={d} that it has no read permission for", .{ process.id, region_index });
        return error.NoPermission;
    }
    if (permissions.writable and !region_entry.permissions.writable) {
        log.warn("Process id={d} tried to share Region index={d} that it has no write permission for", .{ process.id, region_index });
        return error.NoPermission;
    }
    if (permissions.executable and !region_entry.permissions.executable) {
        log.warn("Process id={d} tried to share Region index={d} that it has no execute permission for", .{ process.id, region_index });
        return error.NoPermission;
    }

    process.lock.unlock();
    defer process.lock.lock();

    const recipient = proc.processFromId(recipient_id) orelse {
        log.warn("Process id={d} tried to share Region index={d} to Process with invalid id={d}", .{ process.id, region_index, recipient_id });
        return error.InvalidParameter;
    };
    defer recipient.lock.unlock();

    log.debug("Process id={d} is sharing Region index={d} with Process id={d} with permissions={}", .{ process.id, region_index, recipient_id, permissions });

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

    const region = Region.fromIndex(region_index) catch |err| {
        log.warn("Process id={d} tried to refcount Region with invalid index={d}", .{ process.id, region_index });
        return err;
    };
    _ = process.hasRegion(region) orelse {
        log.warn("Process id={d} tried to refcount unowned Region index={d}", .{ process.id, region_index });
        return error.NoPermission;
    };

    log.debug("Process id={d} is getting the reference count of the Region index={d}", .{ process.id, region_index });

    return region.refCount();
}

pub const UnmapError = libt.syscall.UnmapError;
pub fn unmap(process: *Process) UnmapError!usize {
    const address = process.context.a1;

    const region_entry = process.hasRegionAtAddress(address) orelse {
        log.warn("Process id={d} tried unmap a Region address=0x{x} where there is no Region mapped", .{ process.id, address });
        return error.InvalidParameter;
    };

    log.debug("Process id={d} is unmapping Region address=0x{x}", .{ process.id, address });

    process.unmapRegionEntry(region_entry) catch unreachable;
    return region_entry.region.?.index();
}

pub const FreeError = libt.syscall.FreeError;
pub fn free(process: *Process) FreeError!usize {
    const region_index = process.context.a1;

    const region = Region.fromIndex(region_index) catch |err| {
        log.warn("Process id={d} tried to free Region with invalid index={d}", .{ process.id, region_index });
        return err;
    };
    const region_entry = process.hasRegion(region) orelse {
        log.warn("Process id={d} tried to free unowned Region index={d}", .{ process.id, region_index });
        return error.NoPermission;
    };

    log.debug("Process id={d} is freeing Region index={d}", .{ process.id, region_index });

    process.freeRegionEntry(region_entry) catch |err| {
        log.warn("Process id={d} tried to free mapped Region index={d}", .{ process.id, region_index });
        return err;
    };
    return 0;
}

// TODO: Allow waiting on interrupts.
pub const WaitError = libt.syscall.WaitError;
pub fn wait(process: *Process) WaitError!usize {
    assert(process.wait_reason_count == 0);
    const reasons_count = process.context.a1;
    const reasons_int = process.context.a2;

    if (reasons_count != 0 and reasons_int != 0) {
        const reasons_start: [*]libt.syscall.WaitReason = @ptrFromInt(reasons_int);
        const reasons: []libt.syscall.WaitReason = reasons_start[0..reasons_count];

        for (0.., reasons) |index, *reason| {
            const result = if (reason.tag == .futex) blk: {
                const virtual_address = @intFromPtr(reason.payload.futex.address);
                const expected_value = reason.payload.futex.expected_value;
                break :blk proc.Futex.wait(process, virtual_address, expected_value);
            } else if (reason.tag == .child_process) blk: {
                const child_pid = reason.payload.child_process.pid;
                break :blk process.waitChildProcess(child_pid);
            } else blk: {
                break :blk error.InvalidParameter;
            };
            result catch |err| {
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

    log.debug("Process id={d} is waiting with {d} reasons", .{ process.id, reasons_count });

    process.lock.unlock();
    proc.scheduler.scheduleNext(null, process.context.hart_index);
}

pub const WakeError = libt.syscall.WakeError;
pub fn wake(process: *Process) WakeError!usize {
    const virtual_address = process.context.a1;
    const waiter_count = process.context.a2;
    return proc.Futex.wake(process, virtual_address, waiter_count);
}
