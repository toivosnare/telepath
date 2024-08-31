const std = @import("std");
const log = std.log;
const assert = std.debug.assert;
const mem = std.mem;
const libt = @import("libt");
const proc = @import("../proc.zig");
const mm = @import("../mm.zig");
const Region = mm.Region;
const Process = proc.Process;

pub const Result = usize;

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

pub fn identify(process: *Process) Result {
    return process.id;
}

pub fn fork(process: *Process) !Result {
    log.debug("Process with ID {d} is forking.", .{process.id});

    const child_process = try proc.allocate();
    errdefer child_process.deinit();

    try process.children.append(child_process);
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

pub fn spawn(process: *Process) !Result {
    log.debug("Process with ID {d} is spawning.", .{process.id});

    const region_amount = process.context.register_file.a1;
    if (region_amount == 0)
        return error.InvalidParameter;

    const region_descriptions_int = process.context.register_file.a2;
    if (region_descriptions_int == 0)
        return error.InvalidParameter;

    const region_descriptions_ptr: [*]libt.RegionDescription = @ptrFromInt(region_descriptions_int);
    const region_descriptions: []libt.RegionDescription = region_descriptions_ptr[0..region_amount];
    const entry_point = process.context.register_file.a3;

    for (region_descriptions) |region_description| {
        if (region_description.region_index >= Region.MAX_REGIONS)
            return error.InvalidParameter;
        const region = &Region.table[region_description.region_index];
        if (region.isFree())
            return error.InvalidParameter;

        const region_entry = for (process.region_entries) |region_entry| {
            if (region_entry.region == null)
                continue;
            if (region_entry.region.? == region)
                break region_entry;
        } else {
            return error.NoPermission;
        };

        if (region_description.readable and !region_entry.permissions.readable)
            return error.NoPermission;
        if (region_description.writable and !region_entry.permissions.writable)
            return error.NoPermission;
        if (region_description.executable and !region_entry.permissions.executable)
            return error.NoPermission;
    }

    const child_process = try proc.allocate();
    errdefer child_process.deinit();

    try process.children.append(child_process);
    child_process.parent = process;

    for (region_descriptions) |region_description| {
        const region = &Region.table[region_description.region_index];
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

pub fn kill(process: *Process) !Result {
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
