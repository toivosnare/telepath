const std = @import("std");
const log = std.log;
const mem = std.mem;
const proc = @import("../proc.zig");
const Process = proc.Process;
const Hart = proc.Hart;
const mm = @import("../mm.zig");
const PhysicalPageNumber = mm.PhysicalPageNumber;
const entry = @import("../entry.zig");
const riscv = @import("../riscv.zig");
const sbi = @import("sbi");
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;

const quantum_ns: usize = 1_000_000;

var lock: Spinlock = .{};
var head: ?*Process = null;
var tail: ?*Process = null;

pub fn scheduleNext(current_process: ?*Process, hart_index: Hart.Index) noreturn {
    const next_process = if (pop()) |next| blk: {
        log.debug("Scheduling next.", .{});
        next.state = .running;
        next.context.hart_index = hart_index;

        riscv.satp.write(.{
            .ppn = @bitCast(PhysicalPageNumber.fromPageTable(next.page_table)),
            .asid = 0,
            .mode = .sv39,
        });
        riscv.@"sfence.vma"(null, null);
        next.waitCopyResult();

        next.lock.unlock();

        if (current_process) |current|
            enqueue(current);

        break :blk next;
    } else if (current_process != null) blk: {
        log.debug("Scheduling current.", .{});
        break :blk current_process.?;
    } else {
        log.debug("Entering idle.", .{});
        sbi.time.setTimer(riscv.time.read() + proc.ticks_per_ns * quantum_ns);
        idle(@intFromPtr(&mm.kernel_stack) + (hart_index + 1) * entry.KERNEL_STACK_SIZE_PER_HART, hart_index);
    };

    if (current_process == null)
        riscv.sstatus.clear(.spp);
    sbi.time.setTimer(riscv.time.read() + proc.ticks_per_ns * quantum_ns);
    returnToUserspace(&next_process.context);
}

fn pop() ?*Process {
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

pub fn scheduleCurrent(current_process: *Process) noreturn {
    returnToUserspace(&current_process.context);
}

extern fn returnToUserspace(context: *Process.Context) noreturn;
extern fn idle(stack_pointer: usize, hart_index: Hart.Index) noreturn;

// Process lock must be held, i think?
pub fn enqueue(process: *Process) void {
    log.debug("Adding process with ID {d} to the process queue.", .{process.id});
    lock.lock();
    defer lock.unlock();

    if (tail) |t| {
        t.scheduler_next = process;
    } else {
        head = process;
    }
    tail = process;
    process.scheduler_next = null;

    process.state = .ready;
}

pub fn remove(process: *Process) void {
    log.debug("Removing process with ID {d} from the process queue.", .{process.id});
    lock.lock();
    defer lock.unlock();

    var prev: ?*Process = null;
    var current: ?*Process = head;
    while (current) |c| {
        if (c == process) {
            if (prev) |p| {
                p.scheduler_next = process.scheduler_next;
            } else {
                head = process.scheduler_next;
            }
            if (process == tail)
                tail = prev;
            break;
        }
        prev = current;
        current = c.scheduler_next;
    }
}
