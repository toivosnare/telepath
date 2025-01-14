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

var lock: Spinlock = .{};
var head: ?*Thread = null;
var tail: ?*Thread = null;

pub fn schedule(current_thread: ?*Thread, next_thread: *Thread, hart_index: Hart.Index) noreturn {
    log.debug("Scheduling Thread id={d} on hart index={d}", .{ next_thread.id, hart_index });
    switchContext(current_thread, next_thread, hart_index);
    if (current_thread == null)
        riscv.sstatus.clear(.spp);
    sbi.time.setTimer(riscv.time.read() + proc.ticks_per_us * quantum_us);
    returnToUserspace(&next_thread.context);
}

pub fn scheduleNext(current_thread: ?*Thread, hart_index: Hart.Index) noreturn {
    log.debug("Scheduling on hart index={d}", .{hart_index});
    const next_thread = if (pop()) |next| blk: {
        switchContext(current_thread, next, hart_index);
        break :blk next;
    } else if (current_thread != null) blk: {
        log.debug("No threads in the ready queue. Continuing with Thread id={d} on hart index={d}", .{ current_thread.?.id, hart_index });
        break :blk current_thread.?;
    } else {
        log.debug("No threads in the ready queue. Entering idle on hart index={d}", .{hart_index});
        sbi.time.setTimer(riscv.time.read() + proc.ticks_per_us * quantum_us);
        idle(@intFromPtr(&mm.kernel_stack) + (hart_index + 1) * entry.kernel_stack_size_per_hart, hart_index);
    };

    if (current_thread == null)
        riscv.sstatus.clear(.spp);
    sbi.time.setTimer(riscv.time.read() + proc.ticks_per_us * quantum_us);
    returnToUserspace(&next_thread.context);
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

    riscv.satp.write(.{
        .ppn = @bitCast(PhysicalPageNumber.fromPageTable(next_thread.process.page_table)),
        .asid = 0,
        .mode = .sv39,
    });
    riscv.@"sfence.vma"(null, null);
    next_thread.waitCopyResult();

    next_thread.lock.unlock();

    // FIXME: we are not holding current.lock here?
    if (current_thread) |current|
        enqueue(current);
}

fn pop() ?*Thread {
    while (true) {
        lock.lock();

        if (head) |h| {
            if (!h.lock.tryLock()) {
                lock.unlock();
                // Add some delay.
                for (0..10) |i|
                    mem.doNotOptimizeAway(i);
                continue;
            }
            head = h.scheduler_next;
            h.scheduler_next = null;
            if (h == tail)
                tail = null;
            lock.unlock();
            return h;
        } else {
            lock.unlock();
            return null;
        }
    }
}

extern fn returnToUserspace(context: *Thread.Context) noreturn;
extern fn idle(stack_pointer: usize, hart_index: Hart.Index) noreturn;

// Thread lock must be held, i think?
pub fn enqueue(thread: *Thread) void {
    log.debug("Adding Thread id={d} to the scheduling queue", .{thread.id});
    lock.lock();
    defer lock.unlock();

    if (tail) |t| {
        t.scheduler_next = thread;
    } else {
        head = thread;
    }
    tail = thread;
    thread.scheduler_next = null;

    thread.state = .ready;
}

pub fn remove(thread: *Thread) void {
    log.debug("Removing Thread id={d} from the process queue", .{thread.id});
    lock.lock();
    defer lock.unlock();

    var prev: ?*Thread = null;
    var current: ?*Thread = head;
    while (current) |c| {
        if (c == thread) {
            if (prev) |p| {
                p.scheduler_next = thread.scheduler_next;
            } else {
                head = thread.scheduler_next;
            }
            if (thread == tail)
                tail = prev;
            break;
        }
        prev = current;
        current = c.scheduler_next;
    }
}

pub fn onAddressTranslationEnabled() void {
    head = mm.kernelVirtualFromPhysical(head.?);
    tail = mm.kernelVirtualFromPhysical(tail.?);
}
