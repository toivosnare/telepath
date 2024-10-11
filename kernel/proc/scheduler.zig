const std = @import("std");
const log = std.log.scoped(.@"proc.scheduler");
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

const quantum_ns: usize = 50_000;

var lock: Spinlock = .{};
var head: ?*Process = null;
var tail: ?*Process = null;

pub fn scheduleNext(current_process: ?*Process, hart_index: Hart.Index) noreturn {
    log.debug("Scheduling on hart index={d}", .{hart_index});
    const next_process = if (pop()) |next| blk: {
        log.debug("Switching context to Process id={d} on hart index={d}", .{ next.id, hart_index });
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

        // FIXME: we are not holding current.lock here?
        if (current_process) |current|
            enqueue(current);

        break :blk next;
    } else if (current_process != null) blk: {
        log.debug("No processes in the ready queue. Continuing with Process id={d} on hart index={d}", .{ current_process.?.id, hart_index });
        break :blk current_process.?;
    } else {
        log.debug("No processes in the ready queue. Entering idle on hart index={d}", .{hart_index});
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
    current_process.lock.unlock();
    log.debug("Continuing with Process id={d} on hart index={d}", .{ current_process.id, current_process.context.hart_index });
    returnToUserspace(&current_process.context);
}

extern fn returnToUserspace(context: *Process.Context) noreturn;
extern fn idle(stack_pointer: usize, hart_index: Hart.Index) noreturn;

// Process lock must be held, i think?
pub fn enqueue(process: *Process) void {
    log.debug("Adding Process id={d} to the process queue", .{process.id});
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
    log.debug("Removing Process id={d} from the process queue", .{process.id});
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
