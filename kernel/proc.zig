const std = @import("std");
const log = std.log;
const math = std.math;
const mem = std.mem;
const mm = @import("mm.zig");
const riscv = @import("riscv.zig");
const sbi = @import("sbi");
const PhysicalPageNumber = mm.PhysicalPageNumber;
const PageTable = mm.PageTable;

pub const Process = @import("proc/Process.zig");

const MAX_PROCESSES = 64;
pub var table: [MAX_PROCESSES]Process = undefined;
pub var queue_head: ?*Process = null;
pub var queue_tail: ?*Process = null;

pub const MAX_HARTS = 8;
pub var hart_array: [MAX_HARTS]Hart = undefined;
pub var harts: []Hart = undefined;

pub const Hart = extern struct {
    id: Id,
    pub const Id = usize;
    pub const Index = usize;
};

pub const quantum_ns: usize = 1_000_000;

var next_pid: Process.Id = 2;

pub fn init() *Process {
    log.info("Initializing process subsystem.", .{});
    for (&table) |*p| {
        p.id = 0;
        p.parent = null;
        p.children = Process.Children.init(0) catch unreachable;
        for (&p.region_entries) |*re| {
            re.region = null;
        }
        p.region_entries_head = null;
        p.wait_address = 0;
        p.prev = null;
        p.next = null;
    }

    const init_process = &table[0];
    init_process.id = 1;
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

pub fn scheduleNext(current_process: ?*Process, hart_index: Hart.Index) noreturn {
    var next_process: *Process = undefined;

    if (queue_head) |next| {
        dequeue(next);
        if (current_process) |cur|
            enqueue(cur);
        riscv.satp.write(.{
            .ppn = @bitCast(PhysicalPageNumber.fromPageTable(next.page_table)),
            .asid = 0,
            .mode = .sv39,
        });
        riscv.@"sfence.vma"(null, null);
        next.context.hart_index = hart_index;
        next_process = next;
    } else if (current_process != null) {
        next_process = current_process.?;
    } else {
        idle(hart_index);
    }

    sbi.time.setTimer(riscv.time.read() + 10 * quantum_ns);
    returnToUserspace(&next_process.context);
}

pub fn scheduleCurrent(current_process: *Process) noreturn {
    returnToUserspace(&current_process.context);
}

extern fn returnToUserspace(context: *Process.Context) noreturn;

fn idle(hart_index: Hart.Index) noreturn {
    // TODO: interrupts? Other harts should send IPI to wake up.
    asm volatile (
        \\ csrw sscratch, %[sscratch]
        \\ mv a1, %[hart_index]
        \\1:
        \\ wfi
        \\ j 1b
        :
        : [sscratch] "r" (0),
          [hart_index] "r" (hart_index),
    );
    unreachable;
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

pub fn processFromId(id: Process.Id) ?*Process {
    for (&table) |*process| {
        if (process.id == id)
            return process;
    }
    return null;
}
