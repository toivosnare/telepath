const std = @import("std");
const log = std.log;
const assert = std.debug.assert;
const mem = std.mem;
const libt = @import("libt");
const proc = @import("../proc.zig");
const mm = @import("../mm.zig");
const Region = mm.Region;
const Process = proc.Process;

pub fn exit(process: *Process) *Process {
    const exit_code = process.context.register_file.a1;
    log.debug("Process with PID {d} is exiting with exit code {d}.", .{ process.id, exit_code });
    process.deinit();

    if (proc.queue_head == null)
        @panic("nothing to run");
    const next_process = proc.queue_head.?;
    proc.dequeue(next_process);
    proc.contextSwitch(next_process);
    return next_process;
}

pub const IdentifyError = libt.syscall.IdentifyError;
pub fn identify(process: *Process) IdentifyError!usize {
    return process.id;
}

pub const ForkError = libt.syscall.ForkError;
pub fn fork(process: *Process) ForkError!usize {
    log.debug("Process with ID {d} is forking.", .{process.id});

    const child_process = try proc.allocate();
    errdefer child_process.deinit();

    process.children.append(child_process) catch return error.OutOfMemory;
    child_process.parent = process;

    // TODO: copy region entries properly.
    child_process.region_entries_head = process.region_entries_head;

    @memcpy(
        mem.asBytes(&child_process.context.register_file),
        mem.asBytes(&process.context.register_file),
    );
    child_process.context.register_file.a0 = process.id;
    proc.enqueue(child_process);
    return child_process.id;
}

pub const SpawnError = libt.syscall.SpawnError;
pub fn spawn(process: *Process) SpawnError!usize {
    log.debug("Process with ID {d} is spawning.", .{process.id});

    const region_amount = process.context.register_file.a1;
    if (region_amount == 0)
        return error.InvalidParameter;

    const region_descriptions_int = process.context.register_file.a2;
    if (region_descriptions_int == 0)
        return error.InvalidParameter;

    const region_descriptions_ptr: [*]libt.syscall.RegionDescription = @ptrFromInt(region_descriptions_int);
    const region_descriptions: []libt.syscall.RegionDescription = region_descriptions_ptr[0..region_amount];
    const entry_point = process.context.register_file.a3;

    for (region_descriptions) |region_description| {
        const region = try Region.fromIndex(region_description.region_index);
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
    errdefer child_process.deinit();

    process.children.append(child_process) catch return error.OutOfMemory;
    child_process.parent = process;

    for (region_descriptions) |region_description| {
        const region = Region.fromIndex(region_description.region_index) catch unreachable;
        const region_entry = try child_process.receiveRegion(region, .{
            .readable = region_description.readable,
            .writable = region_description.writable,
            .executable = region_description.executable,
        });
        _ = try child_process.mapRegionEntry(region_entry, region_description.start_address);
    }

    child_process.context.register_file.a0 = process.id;
    child_process.context.register_file.pc = entry_point;
    proc.enqueue(child_process);
    return child_process.id;
}

pub const KillError = libt.syscall.KillError;
pub fn kill(process: *Process) KillError!usize {
    const child_process_id = process.context.register_file.a1;
    log.debug("Process with ID {d} is killing child with ID {d}.", .{ process.id, child_process_id });

    const child_process = for (process.children.constSlice()) |child| {
        if (child.id == child_process_id)
            break child;
    } else {
        return error.NoPermission;
    };
    child_process.deinit();
    return 0;
}

pub const AllocateError = libt.syscall.AllocateError;
pub fn allocate(process: *Process) AllocateError!usize {
    const size = process.context.register_file.a1;
    const permissions: libt.syscall.Permissions = @bitCast(process.context.register_file.a2);
    const physical_address = process.context.register_file.a3;
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
    const region_index = process.context.register_file.a1;
    const requested_address = process.context.register_file.a2;
    log.debug("Process with ID {d} is mapping region {d} at 0x{x}.", .{ process.id, region_index, requested_address });

    const region = try Region.fromIndex(region_index);
    const actual_address = try process.mapRegion(region, requested_address);
    return actual_address;
}

pub const ShareError = libt.syscall.ShareError;
pub fn share(process: *Process) ShareError!usize {
    const region_index = process.context.register_file.a1;
    const recipient_id = process.context.register_file.a2;
    const permissions: libt.syscall.Permissions = @bitCast(process.context.register_file.a3);
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
    const region_index = process.context.register_file.a1;
    log.debug("Process with ID {d} is getting the reference count of the region {d}.", .{ process.id, region_index });

    const region = try Region.fromIndex(region_index);
    _ = process.hasRegion(region) orelse return error.NoPermission;
    return region.ref_count;
}

pub const UnmapError = libt.syscall.UnmapError;
pub fn unmap(process: *Process) UnmapError!usize {
    const address = process.context.register_file.a1;
    log.debug("Process with ID {d} is unmapping region at address {d}.", .{ process.id, address });

    const region_entry = process.hasRegionAtAddress(address) orelse return error.InvalidParameter;
    process.unmapRegionEntry(region_entry);
    return region_entry.region.?.index();
}
