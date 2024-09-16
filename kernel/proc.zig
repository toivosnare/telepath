const std = @import("std");
const log = std.log;
const math = std.math;
const mem = std.mem;
const assert = std.debug.assert;
const mm = @import("mm.zig");
const entry = @import("entry.zig");
const riscv = @import("riscv.zig");
const sbi = @import("sbi");
const libt = @import("libt");
const PhysicalAddress = mm.PhysicalAddress;
const PhysicalPageNumber = mm.PhysicalPageNumber;
const PageTable = mm.PageTable;

pub const Process = @import("proc/Process.zig");
pub const Hart = extern struct {
    id: Id,
    pub const Id = usize;
    pub const Index = usize;
};

pub const MAX_HARTS = 8;
pub var hart_array: [MAX_HARTS]Hart = undefined;
pub var harts: []Hart = undefined;

// TODO: read from device tree.
const ticks_per_ns: usize = 10;
const quantum_ns: usize = 1_000_000;
const MAX_PROCESSES = 64;

var table: [MAX_PROCESSES]Process = undefined;
var scheduling_head: ?*Process = null;
var scheduling_tail: ?*Process = null;
var wait_head: ?*Process = null;
var wait_tail: ?*Process = null;
var next_pid: Process.Id = 2;

pub fn init() *Process {
    log.info("Initializing process subsystem.", .{});
    for (&table) |*p| {
        p.id = 0;
        p.parent = null;
        p.children = Process.Children.init(0) catch unreachable;
        p.state = .invalid;
        for (&p.region_entries) |*re| {
            re.region = null;
        }
        p.region_entries_head = null;
        p.clearWait();
        p.scheduling_prev = null;
        p.scheduling_next = null;
        p.wait_prev = null;
        p.wait_next = null;
    }

    const init_process = &table[0];
    init_process.id = 1;
    init_process.state = .ready;
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
    enqueue(init_process);
}

pub fn allocate() !*Process {
    for (&table) |*p| {
        if (p.id == 0) {
            p.id = next_pid;
            next_pid += 1;

            p.state = .ready;
            p.page_table = @ptrCast(try mm.page_allocator.allocate(0));
            @memset(mem.asBytes(p.page_table), 0);

            const logical_index = PageTable.index(@ptrFromInt(mm.logical_start), 2);
            const first_level_entry_count = math.divCeil(usize, mm.logical_size, PageTable.entry_count * PageTable.entry_count) catch unreachable;
            @memcpy(p.page_table.entries[logical_index..].ptr, table[0].page_table.entries[logical_index..][0..first_level_entry_count]);

            const kernel_index = PageTable.index(@ptrFromInt(mm.kernel_start), 2);
            @memcpy(p.page_table.entries[kernel_index..].ptr, table[0].page_table.entries[kernel_index..][0..1]);

            enqueue(p);

            return p;
        }
    }
    return error.OutOfMemory;
}

pub fn free(process: *Process) void {
    for (process.children.slice()) |child|
        free(child);

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
    // slef.page_table = ;
    @memset(mem.asBytes(&process.context), 0);
    process.clearWait();
    dequeue(process);
    unwaitTimeout(process);
}

pub fn scheduleNext(current_process: ?*Process, hart_index: Hart.Index) noreturn {
    var next_process: *Process = undefined;

    if (scheduling_head) |next| {
        log.debug("Scheduling next.", .{});
        dequeue(next);
        if (current_process) |cur| {
            cur.state = .ready;
            enqueue(cur);
        }
        riscv.satp.write(.{
            .ppn = @bitCast(PhysicalPageNumber.fromPageTable(next.page_table)),
            .asid = 0,
            .mode = .sv39,
        });
        riscv.@"sfence.vma"(null, null);
        next.waitComplete();
        next.context.hart_index = hart_index;
        next_process = next;
    } else if (current_process != null) {
        log.debug("Scheduling current.", .{});
        next_process = current_process.?;
    } else {
        log.debug("Entering idle.", .{});
        sbi.time.setTimer(riscv.time.read() + ticks_per_ns * quantum_ns);
        idle(@intFromPtr(&mm.kernel_stack) + (hart_index + 1) * entry.KERNEL_STACK_SIZE_PER_HART, hart_index);
    }

    if (current_process == null)
        riscv.sstatus.clear(.spp);
    next_process.state = .running;
    sbi.time.setTimer(riscv.time.read() + ticks_per_ns * quantum_ns);
    returnToUserspace(&next_process.context);
}

pub fn scheduleCurrent(current_process: *Process) noreturn {
    returnToUserspace(&current_process.context);
}

extern fn returnToUserspace(context: *Process.Context) noreturn;
extern fn idle(stack_pointer: usize, hart_index: Hart.Index) noreturn;

fn enqueue(process: *Process) void {
    log.debug("Adding process with ID {d} to the process queue.", .{process.id});
    process.scheduling_prev = scheduling_tail;
    process.scheduling_next = null;
    if (scheduling_tail) |tail| {
        tail.scheduling_next = process;
    } else {
        scheduling_head = process;
    }
    scheduling_tail = process;
}

fn dequeue(process: *Process) void {
    log.debug("Removing process with ID {d} from the process queue.", .{process.id});
    if (process.scheduling_prev) |prev| {
        prev.scheduling_next = process.scheduling_next;
    } else if (scheduling_head == process) {
        scheduling_head = process.scheduling_next;
    }
    if (process.scheduling_next) |next| {
        next.scheduling_prev = process.scheduling_prev;
    } else if (scheduling_tail == process) {
        scheduling_tail = process.scheduling_prev;
    }
    process.scheduling_prev = null;
    process.scheduling_next = null;
}

pub fn waitTimeout(process: *Process, timeout_ns: u64) void {
    assert(process.wait_prev == null);
    assert(process.wait_next == null);

    if (timeout_ns == math.maxInt(u64))
        return;

    // TODO: Can overflow?
    process.wait_end_time = riscv.time.read() + ticks_per_ns * timeout_ns;

    process.wait_prev = wait_tail;
    process.wait_next = null;
    while (process.wait_prev) |prev| {
        if (prev.wait_end_time <= process.wait_end_time)
            break;
        process.wait_next = process.wait_prev;
        process.wait_prev = prev.wait_prev;
    }

    if (process.wait_prev) |prev| {
        prev.wait_next = process;
    } else {
        wait_head = process;
    }
    if (process.wait_next) |next| {
        next.wait_prev = process;
    } else {
        wait_tail = process;
    }
}

fn unwaitTimeout(process: *Process) void {
    if (process.wait_prev) |prev| {
        prev.wait_next = process.wait_next;
    } else {
        wait_head = process.wait_next;
    }
    if (process.wait_next) |next| {
        next.wait_prev = process.wait_prev;
    } else {
        wait_tail = process.wait_prev;
    }

    process.wait_prev = null;
    process.wait_next = null;
    process.wait_end_time = 0;
}

pub fn checkWaitTimeout(time: u64) void {
    var process: ?*Process = wait_head;
    while (process) |p| {
        if (p.wait_end_time > time) {
            wait_head = p;
            p.wait_prev = null;
            return;
        }
        process = p.wait_next;

        assert(p.state == .waiting);
        p.context.a0 = libt.syscall.packResult(error.Timeout);
        p.clearWait();
        p.wait_prev = null;
        p.wait_next = null;
        p.wait_end_time = 0;
        enqueue(p);
    }

    wait_head = null;
    wait_tail = null;
}

pub fn checkWaitFutex(address: PhysicalAddress, waiter_count: usize) usize {
    // TODO: Use something faster than linear search.
    var w = waiter_count;
    for (&table) |*p| {
        if (w == 0)
            break;
        if (p.state != .waiting)
            continue;

        const completed, const futeces_woken = p.checkWaitFutex(address);
        if (completed) {
            p.state = .ready;
            unwaitTimeout(p);
            enqueue(p);
        }
        w -= futeces_woken;
    }
    return waiter_count - w;
}

pub fn checkWaitChildProcess(child: *Process, exit_code: usize) void {
    if (child.parent) |parent| {
        if (parent.state != .waiting)
            return;
        if (parent.checkWaitChildProcess(child.id, exit_code)) {
            parent.state = .ready;
            unwaitTimeout(parent);
            enqueue(parent);
        }
    }
}

pub fn processFromId(id: Process.Id) ?*Process {
    for (&table) |*process| {
        if (process.id == id)
            return process;
    }
    return null;
}
