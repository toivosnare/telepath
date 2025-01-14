const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"proc.timeout");
const math = std.math;
const mem = std.mem;
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;
const riscv = @import("../riscv.zig");
const proc = @import("../proc.zig");
const Thread = proc.Thread;

var lock: Spinlock = .{};
var head: ?*Thread = null;

pub fn wait(thread: *Thread, timeout_us: u64) void {
    assert(thread.wait_timeout_next == null);
    if (timeout_us == math.maxInt(u64))
        return;

    log.debug("Adding Thread id={d} to the timeout queue with timeout of {d} us", .{ thread.id, timeout_us });

    // FIXME: Can overflow?
    thread.wait_timeout_time = riscv.time.read() + proc.ticks_per_us * timeout_us;

    lock.lock();
    defer lock.unlock();

    var prev: ?*Thread = null;
    var next: ?*Thread = head;
    while (next) |n| {
        if (n.wait_timeout_time > thread.wait_timeout_time)
            break;
        prev = next;
        next = n.wait_timeout_next;
    }

    thread.wait_timeout_next = next;
    if (prev) |p| {
        p.wait_timeout_next = thread;
    } else {
        head = thread;
    }
}

pub fn remove(thread: *Thread) void {
    log.debug("Removing Thread id={d} from the timeout queue", .{thread.id});

    lock.lock();
    defer lock.unlock();

    var prev: ?*Thread = null;
    var curr: ?*Thread = head;
    while (curr) |c| {
        if (c == thread) {
            if (prev) |p| {
                p.wait_timeout_next = thread.wait_timeout_next;
            } else {
                head = thread.wait_timeout_next;
            }
            thread.wait_timeout_next = null;
            thread.wait_timeout_time = 0;
            break;
        }
        prev = curr;
        curr = c.wait_timeout_next;
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
            log.debug("Thread id={d} timed out", .{h.id});
            head = h.wait_timeout_next;
            h.wait_timeout_next = null;
            h.wait_timeout_time = 0;
            h.waitRemove();
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
