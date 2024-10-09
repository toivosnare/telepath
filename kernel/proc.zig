const std = @import("std");
const log = std.log;
const math = std.math;
const mem = std.mem;
const assert = std.debug.assert;
const atomic = std.atomic;
const mm = @import("mm.zig");
const entry = @import("entry.zig");
const riscv = @import("riscv.zig");
const sbi = @import("sbi");
const libt = @import("libt");
const PhysicalAddress = mm.PhysicalAddress;
const KernelVirtualAddress = mm.KernelVirtualAddress;
const PhysicalPageNumber = mm.PhysicalPageNumber;
const PageTable = mm.PageTable;

pub const Process = @import("proc/Process.zig");
pub const scheduler = @import("proc/scheduler.zig");
pub const Futex = @import("proc/Futex.zig");
pub const timeout = @import("proc/timeout.zig");

pub const Hart = extern struct {
    id: Id,
    pub const Id = usize;
    pub const Index = usize;
};

pub const MAX_HARTS = 8;
pub var hart_array: [MAX_HARTS]Hart = undefined;
pub var harts: []Hart = undefined;

// TODO: read from device tree.
pub const ticks_per_ns: usize = 10;
const MAX_PROCESSES = 64;

pub var table: [MAX_PROCESSES]Process = undefined;
var next_pid: atomic.Value(Process.Id) = atomic.Value(Process.Id).init(2);

pub fn init() *Process {
    log.info("Initializing process subsystem.", .{});
    for (&table) |*p| {
        p.lock = .{};
        p.id = 0;
        p.parent = null;
        p.children = Process.Children.init(0) catch unreachable;
        p.state = .invalid;
        for (&p.region_entries) |*re| {
            re.region = null;
        }
        p.region_entries_head = null;
        @memset(mem.asBytes(&p.context), 0);
        p.waitClear();
        p.scheduler_next = null;
        p.killed = false;
    }

    const init_process = &table[0];
    init_process.id = 1;
    init_process.state = .waiting;
    init_process.page_table = @ptrCast(mm.page_allocator.allocate(0) catch @panic("OOM"));
    @memset(mem.asBytes(init_process.page_table), 0);
    return init_process;
}

pub fn onAddressTranslationEnabled() void {
    harts.ptr = mm.kernelVirtualFromPhysical(harts.ptr);
    const init_process = &table[0];
    init_process.page_table = mm.logicalFromPhysical(init_process.page_table);
    init_process.region_entries_head = mm.kernelVirtualFromPhysical(init_process.region_entries_head.?);
    var region_entry: ?*Process.RegionEntry = init_process.region_entries_head;
    while (region_entry) |re| : (region_entry = re.next) {
        if (re.region != null)
            re.region = mm.kernelVirtualFromPhysical(re.region.?);
        if (re.prev != null)
            re.prev = mm.kernelVirtualFromPhysical(re.prev.?);
        if (re.next != null)
            re.next = mm.kernelVirtualFromPhysical(re.next.?);
    }
    riscv.sstatus.clear(.spp);
    Futex.init();
    scheduler.enqueue(init_process);
}

pub fn allocate() !*Process {
    for (&table) |*p| {
        if (!p.lock.tryLock())
            continue;

        if (p.state == .invalid) {
            p.id = next_pid.fetchAdd(1, .monotonic);

            p.page_table = @ptrCast(try mm.page_allocator.allocate(0));
            @memset(mem.asBytes(p.page_table), 0);

            const logical_index = PageTable.index(@ptrFromInt(mm.logical_start), 2);
            const first_level_entry_count = math.divCeil(usize, mm.logical_size, PageTable.entry_count * PageTable.entry_count) catch unreachable;
            @memcpy(p.page_table.entries[logical_index..].ptr, table[0].page_table.entries[logical_index..][0..first_level_entry_count]);

            const kernel_index = PageTable.index(@ptrFromInt(mm.kernel_start), 2);
            @memcpy(p.page_table.entries[kernel_index..].ptr, table[0].page_table.entries[kernel_index..][0..1]);

            return p;
        }
        p.lock.unlock();
    }
    return error.OutOfMemory;
}

pub fn free(process: *Process) void {
    process.id = 0;
    process.parent = null;
    process.children.resize(0) catch unreachable;
    process.state = .invalid;
    for (&process.region_entries) |*region_entry| {
        if (region_entry.region == null)
            continue;
        process.unmapRegionEntry(region_entry) catch {};
        process.freeRegionEntry(region_entry) catch unreachable;
    }
    process.region_entries_head = null;
    // TODO: page table?
    // self.page_table = ;
    @memset(mem.asBytes(&process.context), 0);
    process.waitClear();
    process.scheduler_next = null;
    process.killed = false;
}

pub fn processFromId(id: Process.Id) ?*Process {
    for (&table) |*process| {
        process.lock.lock();
        if (process.id == id)
            return process;
        process.lock.unlock();
    }
    return null;
}

// Black magic.
pub fn processFromWaitReason(wait_reason: *Process.WaitReason) *Process {
    return @ptrFromInt(mem.alignBackwardAnyAlign(@intFromPtr(wait_reason) - @intFromPtr(&table[0]), @sizeOf(Process)) + @intFromPtr(&table[0]));
}
