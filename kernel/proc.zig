const std = @import("std");
const log = std.log;
const math = std.math;
const mem = std.mem;
const mm = @import("mm.zig");
const csr = @import("csr.zig");
const PhysicalPageNumber = mm.PhysicalPageNumber;
const PageTable = mm.PageTable;

pub const Process = @import("proc/Process.zig");

const MAX_PROCESSES = 64;
pub var table: [MAX_PROCESSES]Process = undefined;
pub var queue_head: ?*Process = null;
pub var queue_tail: ?*Process = null;

pub const MAX_HARTS = 8;
pub const HartId = usize;
pub const HartIndex = usize;
pub var hart_id_array: [MAX_HARTS]HartId = undefined;
pub var hart_ids: []HartId = undefined;

pub const quantum_ns: usize = 1_000_000;

pub fn init() void {
    log.info("Initializing process subsystem.", .{});
    for (1.., &table) |pid, *p| {
        p.id = pid;
        p.parent = null;
        p.children = Process.Children.init(0) catch unreachable;
        p.state = .invalid;
        for (&p.region_entries) |*re| {
            re.region = null;
        }
        p.region_entries_head = null;
        p.prev = null;
        p.next = null;
    }
}

pub fn onAddressTranslationEnabled() *Process {
    hart_ids.ptr = mm.kernelVirtualFromPhysical(hart_ids.ptr);
    const init_process = &table[0];
    init_process.page_table = mm.logicalFromPhysical(init_process.page_table);
    init_process.region_entries_head = mm.kernelVirtualFromPhysical(init_process.region_entries_head.?);
    var region_entry: ?*Process.RegionEntry = init_process.region_entries_head;
    while (region_entry) |re| : (region_entry = re.next) {
        if (re.region != null) {
            re.region = mm.kernelVirtualFromPhysical(re.region.?);
            re.region.?.allocation.ptr = mm.logicalFromPhysical(re.region.?.allocation.ptr);
        }
        if (re.prev != null)
            re.prev = mm.kernelVirtualFromPhysical(re.prev.?);
        if (re.next != null)
            re.next = mm.kernelVirtualFromPhysical(re.next.?);
    }
    return init_process;
}

var joo: bool = false;

pub fn allocate() !*Process {
    for (&table) |*p| {
        if (p.state == .invalid) {
            p.page_table = @ptrCast(try mm.page_allocator.allocate(0));
            @memset(mem.asBytes(p.page_table), 0);
            // TODO: map logical mapping and kernel.
            if (joo) {
                const logical_index = PageTable.index(@ptrFromInt(mm.logical_start), 2);
                const first_level_entry_count = math.divCeil(usize, mm.logical_size, PageTable.entry_count * PageTable.entry_count) catch unreachable;
                @memcpy(p.page_table.entries[logical_index..].ptr, table[0].page_table.entries[logical_index..][0..first_level_entry_count]);

                const kernel_index = PageTable.index(@ptrFromInt(mm.kernel_start), 2);
                @memcpy(p.page_table.entries[kernel_index..].ptr, table[0].page_table.entries[kernel_index..][0..1]);
            } else {
                joo = true;
            }

            p.state = .waiting;
            return p;
        }
    }
    return error.ProcessTableFull;
}

pub fn enqueue(process: *Process) void {
    log.debug("Adding process with ID {d} to the process queue.", .{process.id});
    process.prev = queue_tail;
    process.next = null;
    if (queue_tail) |tail| {
        tail.next = process;
    } else {
        queue_head = process;
    }
    queue_tail = process;
    process.state = .ready;
}

pub fn dequeue(process: *Process) void {
    log.debug("Removing process with ID {d} from the process queue.", .{process.id});
    if (process.prev) |prev| {
        prev.next = process.next;
    } else {
        queue_head = process.next;
    }
    if (process.next) |next| {
        next.prev = process.prev;
    } else {
        queue_tail = process.prev;
    }
    process.prev = null;
    process.next = null;
}

pub fn contextSwitch(process: *Process) void {
    log.debug("Switching context to process with ID {d}.", .{process.id});
    process.state = .running;
    // process.context.hart_index = hart_index;
    csr.satp.write(.{
        .ppn = @bitCast(PhysicalPageNumber.fromPageTable(process.page_table)),
        .asid = 0,
        .mode = .sv39,
    });
    asm volatile ("sfence.vma");
}

pub fn processFromId(id: Process.Id) ?*Process {
    for (&table) |*process| {
        if (process.state != .invalid and process.id == id)
            return process;
    }
    return null;
}
