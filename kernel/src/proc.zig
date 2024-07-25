const std = @import("std");
const log = std.log;
const mm = @import("mm.zig");

pub const Process = @import("proc/Process.zig");

const MAX_PROCESSES = 64;
pub var table: [MAX_PROCESSES]Process = undefined;

pub fn init() void {
    log.info("Initializing process subsystem.", .{});
    for (1.., &table) |pid, *p| {
        p.id = pid;
        p.state = .invalid;
        for (&p.children) |*c| {
            c.* = 0;
        }
        for (&p.region_entries) |*re| {
            re.region = null;
        }
        p.region_entries_head = null;
    }
}

pub fn onAddressTranslationEnabled() *Process {
    const init_process = &table[0];
    init_process.page_table = @ptrFromInt(mm.logicalFromPhysical(@intFromPtr(init_process.page_table)));
    init_process.region_entries_head = @ptrFromInt(mm.kernelVirtualFromPhysical(@intFromPtr(init_process.region_entries_head.?)));
    var region_entry: ?*Process.RegionEntry = init_process.region_entries_head;
    while (region_entry) |re| : (region_entry = re.next) {
        re.region = @ptrFromInt(mm.kernelVirtualFromPhysical(@intFromPtr(re.region.?)));
        if (re.prev != null)
            re.prev = @ptrFromInt(mm.kernelVirtualFromPhysical(@intFromPtr(re.prev.?)));
        if (re.next != null)
            re.next = @ptrFromInt(mm.kernelVirtualFromPhysical(@intFromPtr(re.next.?)));
    }
    return init_process;
}

pub fn allocate() !*Process {
    for (&table) |*p| {
        if (p.state == .invalid) {
            p.state = .waiting;
            return p;
        }
    }
    return error.ProcessTableFull;
}
