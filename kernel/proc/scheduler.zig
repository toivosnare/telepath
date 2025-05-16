const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"proc.scheduler");
const mem = std.mem;
const sbi = @import("sbi");
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;
const entry = @import("../entry.zig");
const riscv = @import("../riscv.zig");
const mm = @import("../mm.zig");
const PhysicalPageNumber = mm.PhysicalPageNumber;
const proc = @import("../proc.zig");
const Hart = proc.Hart;
const Thread = proc.Thread;

const quantum_us: usize = 50_000;
// const quantum_us: usize = 1_000_000;
const priority_level_count = 8;

pub const Priority = std.math.IntFittingRange(0, priority_level_count - 1);
pub const max_priority: Priority = priority_level_count - 1;

const Queue = struct {
    head: ?*Thread = null,
    tail: ?*Thread = null,
};

var lock: Spinlock = .{};
var queues: [priority_level_count]Queue = [_]Queue{.{}} ** priority_level_count;

pub fn schedule(current_thread: ?*Thread, next_thread: *Thread, hart_index: Hart.Index) noreturn {
    log.debug("Scheduling Thread id={d} on hart index={d}", .{ next_thread.id, hart_index });
    switchContext(current_thread, next_thread, hart_index);
    if (current_thread == null)
        riscv.sstatus.clear(.spp);
    sbi.time.setTimer(riscv.time.read() + proc.ticks_per_us * quantum_us);
    returnToUserspace(&next_thread.context);
}

pub fn scheduleNext(current_thread: ?*Thread, hart_index: Hart.Index) noreturn {
    var priority: Priority = max_priority;
    const min_priority = if (current_thread) |ct| ct.priority else 0;
    lock.lock();

    const next_thread = while (true) {
        const queue = &queues[priority];
        if (queue.head) |head| {
            if (!head.lock.tryLock()) {
                lock.unlock();
                // Add some delay.
                for (0..10) |i| mem.doNotOptimizeAway(i);
                priority = max_priority;
                lock.lock();
                continue;
            }
            queue.head = head.scheduler_next;
            head.scheduler_next = null;
            if (head == queue.tail) {
                assert(queue.head == null);
                queue.tail = null;
            }
            lock.unlock();
            switchContext(current_thread, head, hart_index);
            break head;
        }

        if (priority == min_priority) {
            lock.unlock();
            break current_thread;
        }
        priority -= 1;
    };

    riscv.sip.clear(.ssip);
    sbi.time.setTimer(riscv.time.read() + proc.ticks_per_us * quantum_us);
    if (next_thread) |nt| {
        riscv.sstatus.clear(.spp);
        returnToUserspace(&nt.context);
    } else {
        proc.harts[hart_index].idling = true;
        idle(@intFromPtr(&mm.kernel_stack) + (hart_index + 1) * entry.kernel_stack_size_per_hart, hart_index);
    }
}

pub fn scheduleCurrent(current_thread: *Thread) noreturn {
    current_thread.lock.unlock();
    log.debug("Continuing with Thread id={d} on hart index={d}", .{ current_thread.id, current_thread.context.hart_index });
    returnToUserspace(&current_thread.context);
}

// next_process.lock must be held but not current_process.lock?
fn switchContext(current_thread: ?*Thread, next_thread: *Thread, hart_index: Hart.Index) void {
    assert(current_thread != next_thread);
    log.debug("Switching context to Thread id={d} on hart index={d}", .{ next_thread.id, hart_index });
    next_thread.state = .running;
    next_thread.context.hart_index = hart_index;

    if (current_thread == null or current_thread.?.process != next_thread.process) {
        riscv.satp.write(.{
            .ppn = @bitCast(PhysicalPageNumber.fromPageTable(next_thread.process.page_table)),
            .asid = 0,
            .mode = .sv39,
        });
        riscv.@"sfence.vma"(null, null);
    }
    next_thread.waitCopyResult();

    next_thread.lock.unlock();

    // FIXME: we are not holding current.lock here?
    if (current_thread) |current|
        enqueue(current);
}

extern fn returnToUserspace(context: *Thread.Context) noreturn;
extern fn idle(stack_pointer: usize, hart_index: Hart.Index) noreturn;

// Thread lock must be held, i think?
pub fn enqueue(thread: *Thread) void {
    log.debug("Adding Thread id={d} to the scheduling queue", .{thread.id});
    lock.lock();
    defer lock.unlock();

    const queue = &queues[thread.priority];
    if (queue.tail) |t| {
        t.scheduler_next = thread;
    } else {
        queue.head = thread;
    }
    queue.tail = thread;

    thread.scheduler_next = null;
    thread.state = .ready;
}

pub fn remove(thread: *Thread) void {
    log.debug("Removing Thread id={d} from the process queue", .{thread.id});
    lock.lock();
    defer lock.unlock();

    const queue = &queues[thread.priority];

    var prev: ?*Thread = null;
    var current: ?*Thread = queue.head;
    while (current) |c| {
        if (c == thread) {
            if (prev) |p| {
                p.scheduler_next = thread.scheduler_next;
            } else {
                queue.head = thread.scheduler_next;
            }
            if (thread == queue.tail)
                queue.tail = prev;
            break;
        }
        prev = current;
        current = c.scheduler_next;
    }
}

pub fn onAddressTranslationEnabled() void {
    queues[max_priority].head = mm.kernelVirtualFromPhysical(queues[max_priority].head.?);
    queues[max_priority].tail = mm.kernelVirtualFromPhysical(queues[max_priority].tail.?);
}
