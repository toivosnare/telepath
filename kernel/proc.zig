const std = @import("std");
const log = std.log.scoped(.proc);
const math = std.math;
const mem = std.mem;
const assert = std.debug.assert;
const atomic = std.atomic;
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;
const riscv = @import("riscv.zig");
const mm = @import("mm.zig");
const PageTable = mm.PageTable;

pub const Process = @import("proc/Process.zig");
pub const Thread = @import("proc/Thread.zig");
pub const Capability = @import("proc/Capability.zig");
pub const Futex = @import("proc/Futex.zig");
pub const scheduler = @import("proc/scheduler.zig");
pub const timeout = @import("proc/timeout.zig");
pub const interrupt = @import("proc/interrupt.zig");

pub const Hart = extern struct {
    id: Id,
    pub const Id = usize;
    pub const Index = usize;
};

pub const max_harts = 8;
pub var hart_array: [max_harts]Hart = undefined;
pub var harts: []Hart = undefined;

pub var ticks_per_us: usize = undefined;
const max_processes = 64;
const max_threads = 64;

const ProcessTableSlot = union {
    process: Process,
    next: ?*ProcessTableSlot,
};

const ThreadTableSlot = union {
    thread: Thread,
    next: ?*ThreadTableSlot,
};

pub var process_table: [max_processes]ProcessTableSlot = undefined;
var process_free_list_head: ?*ProcessTableSlot = undefined;
var process_free_list_lock: Spinlock = .{};
var next_pid: atomic.Value(Process.Id) = atomic.Value(Process.Id).init(2);

var thread_table: [max_threads]ThreadTableSlot = undefined;
var thread_free_list_head: ?*ThreadTableSlot = undefined;
var thread_free_list_lock: Spinlock = .{};
var next_tid: atomic.Value(Thread.Id) = atomic.Value(Thread.Id).init(1);

pub fn init() !*Process {
    log.info("Initializing process subsystem", .{});

    const init_process = &process_table[0].process;
    init_process.id = 1;
    init_process.ref_count = 0;
    init_process.page_table = @ptrCast(try mm.page_allocator.allocate(0));
    init_process.process_caps_head = null;
    init_process.unmapped_region_caps_head = null;
    init_process.mapped_region_caps_head = null;
    init_process.thread_caps_head = null;

    // Prepare one thread table slot for init.
    thread_free_list_head = &thread_table[0];
    thread_free_list_head.?.* = .{ .next = null };

    Capability.init();
    return init_process;
}

pub fn onAddressTranslationEnabled() void {
    harts.ptr = mm.kernelVirtualFromPhysical(harts.ptr);

    var prev_process: *ProcessTableSlot = &process_table[1];
    process_free_list_head = prev_process;
    for (process_table[2..]) |*process| {
        prev_process.* = .{ .next = process };
        prev_process = process;
    }
    prev_process.* = .{ .next = null };

    var prev_thread: *ThreadTableSlot = &thread_table[1];
    thread_free_list_head = prev_thread;
    for (thread_table[2..]) |*thread| {
        prev_thread.* = .{ .next = thread };
        prev_thread = thread;
    }
    prev_thread.* = .{ .next = null };

    const init_process = &process_table[0].process;
    init_process.page_table = mm.logicalFromPhysical(init_process.page_table);
    assert(init_process.process_caps_head == null);
    assert(init_process.unmapped_region_caps_head == null);

    init_process.mapped_region_caps_head = mm.kernelVirtualFromPhysical(init_process.mapped_region_caps_head.?);
    var region_cap: *Capability = init_process.mapped_region_caps_head.?;
    while (true) {
        region_cap.owner = mm.kernelVirtualFromPhysical(region_cap.owner);
        region_cap.object.region = mm.kernelVirtualFromPhysical(region_cap.object.region);
        if (region_cap.next) |next| {
            region_cap.next = mm.kernelVirtualFromPhysical(next);
            region_cap = region_cap.next.?;
        } else {
            break;
        }
    }

    init_process.thread_caps_head = mm.kernelVirtualFromPhysical(init_process.thread_caps_head.?);
    const init_thread_capability = init_process.thread_caps_head.?;
    init_thread_capability.owner = mm.kernelVirtualFromPhysical(init_thread_capability.owner);
    init_thread_capability.object.thread = mm.kernelVirtualFromPhysical(init_thread_capability.object.thread);
    assert(init_thread_capability.next == null);

    const init_thread = init_thread_capability.object.thread;
    init_thread.process = mm.kernelVirtualFromPhysical(init_thread.process);
    assert(init_thread.scheduler_next == null);
    assert(init_thread.waiters_head == null);
    assert(init_thread.wait_timeout_next == null);

    riscv.sstatus.clear(.spp);
    Capability.onAddressTranslationEnabled();
    scheduler.onAddressTranslationEnabled();
    Futex.init();
    interrupt.init();
}

pub fn allocateProcess() !*Process {
    log.debug("Allocating a Process", .{});
    process_free_list_lock.lock();
    defer process_free_list_lock.unlock();

    if (process_free_list_head) |head| {
        process_free_list_head = head.next;
        head.* = .{ .process = undefined };
        const process = &head.process;

        process.page_table = @ptrCast(try mm.page_allocator.allocate(0));
        process.lock = .{};
        process.id = next_pid.fetchAdd(1, .monotonic);
        process.ref_count = 1;
        process.process_caps_head = null;
        process.unmapped_region_caps_head = null;
        process.mapped_region_caps_head = null;
        process.thread_caps_head = null;

        // Copy logical mapping from init process.
        const init_process = &process_table[0].process;
        const logical_index = PageTable.index(@ptrFromInt(mm.logical_start), 2);
        const first_level_entry_count = math.divCeil(usize, mm.logical_size, PageTable.entry_count * PageTable.entry_count) catch unreachable;
        @memcpy(process.page_table.entries[logical_index..].ptr, init_process.page_table.entries[logical_index..][0..first_level_entry_count]);

        // Copy kernel mapping from init process.
        const kernel_index = PageTable.index(@ptrFromInt(mm.kernel_start), 2);
        @memcpy(process.page_table.entries[kernel_index..].ptr, init_process.page_table.entries[kernel_index..][0..1]);

        return process;
    }

    log.warn("Could not find free Process table slot", .{});
    return error.OutOfMemory;
}

pub fn allocateThread() !*Thread {
    log.debug("Allocating a Thread", .{});
    thread_free_list_lock.lock();
    defer thread_free_list_lock.unlock();

    if (thread_free_list_head) |head| {
        thread_free_list_head = head.next;
        head.* = .{ .thread = undefined };
        const thread = &head.thread;

        thread.lock = .{};
        thread.ref_count = 1;
        thread.id = next_tid.fetchAdd(1, .monotonic);
        thread.process = undefined;
        thread.state = .invalid;
        @memset(mem.asBytes(&thread.context), 0);
        thread.scheduler_next = null;
        thread.waiters_head = null;
        thread.exit_code = 0;
        thread.waitClear();

        return thread;
    }
    log.warn("Could not find free Thread table slot", .{});
    return error.OutOfMemory;
}

pub fn freeProcess(process: *Process) void {
    log.debug("Freeing Process id={d}", .{process.id});

    process.lock = .{};
    process.id = 0;
    process.ref_count = 0;
    process.page_table.free();
    process.process_caps_head = null;
    process.unmapped_region_caps_head = null;
    process.mapped_region_caps_head = null;
    process.thread_caps_head = null;

    const slot: *ProcessTableSlot = @ptrCast(process);
    process_free_list_lock.lock();
    slot.next = process_free_list_head;
    process_free_list_head = slot;
    process_free_list_lock.unlock();
}

pub fn freeThread(thread: *Thread) void {
    log.debug("Freeing Thread id={d}", .{thread.id});

    thread.lock = .{};
    thread.ref_count = 0;
    thread.id = 0;
    thread.process = undefined;
    thread.state = .invalid;
    @memset(mem.asBytes(&thread.context), 0);
    thread.scheduler_next = null;
    thread.waiters_head = null;
    thread.exit_code = 0;
    thread.waitClear();

    const slot: *ThreadTableSlot = @ptrCast(thread);
    thread_free_list_lock.lock();
    slot.next = thread_free_list_head;
    thread_free_list_head = slot;
    thread_free_list_lock.unlock();
    @panic("testi");
}

// Black magic.
pub fn threadFromWaitNode(wait_node: *Thread.WaitNode) *Thread {
    return @ptrFromInt(mem.alignBackwardAnyAlign(usize, @intFromPtr(wait_node) - @intFromPtr(&thread_table[0]), @sizeOf(ThreadTableSlot)) + @intFromPtr(&thread_table[0]));
}
