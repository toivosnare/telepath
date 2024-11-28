const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"proc.timeout");
const math = std.math;
const mem = std.mem;
const proc = @import("../proc.zig");
const Process = proc.Process;
const riscv = @import("../riscv.zig");
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;

var lock: Spinlock = .{};
var head: ?*Process = null;

pub fn wait(process: *Process, timeout_us: u64) void {
    assert(process.wait_timeout_next == null);
    if (timeout_us == math.maxInt(u64))
        return;

    log.debug("Adding Process id={d} to the timeout queue with timeout of {d} us", .{ process.id, timeout_us });

    // FIXME: Can overflow?
    process.wait_timeout_time = riscv.time.read() + proc.ticks_per_us * timeout_us;

    lock.lock();
    defer lock.unlock();

    var prev: ?*Process = null;
    var next: ?*Process = head;
    while (next) |n| {
        if (n.wait_timeout_time > process.wait_timeout_time)
            break;
        prev = next;
        next = n.wait_timeout_next;
    }

    process.wait_timeout_next = next;
    if (prev) |p| {
        p.wait_timeout_next = process;
    } else {
        head = process;
    }
}

pub fn remove(process: *Process) void {
    log.debug("Removing Process id={d} from the timeout queue", .{process.id});

    lock.lock();
    defer lock.unlock();

    var prev: ?*Process = null;
    var current: ?*Process = head;
    while (current) |c| {
        if (c == process) {
            if (prev) |p| {
                p.wait_timeout_next = process.wait_timeout_next;
            } else {
                head = process.wait_timeout_next;
            }
            process.wait_timeout_next = null;
            process.wait_timeout_time = 0;
            break;
        }
        prev = current;
        current = c.wait_timeout_next;
    }
}

pub fn check(time: u64) void {
    log.debug("Checking timeout queue", .{});
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
            if (h.wait_timeout_time > time) {
                h.lock.unlock();
                lock.unlock();
                break;
            }
            log.debug("Process id={d} timed out", .{h.id});
            head = h.wait_timeout_next;
            h.wait_timeout_next = null;
            h.wait_timeout_time = 0;
            h.waitReasonsClear();
            h.context.a0 = libt.syscall.packResult(error.Timeout);
            proc.scheduler.enqueue(h);
            h.lock.unlock();
            lock.unlock();
        } else {
            lock.unlock();
            return;
        }
    }
}
