const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.@"proc.interrupt");
const Wyhash = std.hash.Wyhash;
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;
const trap = @import("../trap.zig");
const proc = @import("../proc.zig");
const Hart = proc.Hart;
const Thread = proc.Thread;
const WaitReason = Thread.WaitReason;

const Bucket = struct {
    lock: Spinlock,
    head: ?*WaitReason,
};

const bucket_count = 32;
var buckets: [bucket_count]Bucket = undefined;

pub fn init() void {
    log.info("Initializing interrupt subsystem", .{});
    for (&buckets) |*bucket| {
        bucket.lock = .{};
        bucket.head = null;
    }
}

pub fn wait(wait_reason: *WaitReason, source: u32, hart_index: Hart.Index) void {
    const bucket = bucketOf(source);
    defer bucket.lock.unlock();

    var prev: ?*WaitReason = null;
    var curr: ?*WaitReason = bucket.head;
    while (curr) |c| {
        prev = c;
        curr = c.payload.interrupt.next;
    }
    if (prev) |p| {
        p.payload.interrupt.next = wait_reason;
    } else {
        bucket.head = wait_reason;
    }

    const hart_id = proc.harts[hart_index].id;
    trap.plic.setPriority(source, 1);
    trap.plic.enable(hart_id, source);

    // FIXME: This is pretty bad. Force PLIC to re-evaluate.
    // Needed in case this interrupt was pending before enabling.
    trap.plic.setTreshold(hart_id, 0);
}

pub fn check(thread: ?*Thread, idle_hart_index: Hart.Index) noreturn {
    const hart_index = if (thread) |t| t.context.hart_index else idle_hart_index;
    const hart_id = proc.harts[hart_index].id;
    const source = trap.plic.claim(hart_id);

    const bucket = bucketOf(source);

    outer: while (true) {
        var prev: ?*WaitReason = null;
        var curr: ?*WaitReason = bucket.head;
        while (curr) |c| {
            const owner = proc.threadFromWaitReason(c);
            if (!owner.lock.tryLock()) {
                bucket.lock.unlock();
                // Add some delay.
                for (0..10) |i|
                    mem.doNotOptimizeAway(i);
                bucket.lock.lock();
                continue :outer;
            }

            if (c.payload.interrupt.source != source) {
                prev = c;
                curr = c.payload.interrupt.next;
                owner.lock.unlock();
                continue;
            }

            log.debug("Thread id={d} received interrupt source=0x{x}", .{ owner.id, source });
            if (prev) |p| {
                p.payload.interrupt.next = c.payload.interrupt.next;
            } else {
                bucket.head = c.payload.interrupt.next;
            }
            owner.waitComplete(c, 0);
            trap.plic.disable(hart_id, source);
            trap.disableInterrupts();
            bucket.lock.unlock();
            proc.scheduler.schedule(thread, owner, hart_index);
        }
        @panic("no interrupt handler");
    }
}

pub fn complete(thread: *Thread, source: u32) void {
    log.debug("Thread id={d} completed interrupt source=0x{x}", .{ thread.id, source });
    const hart_index = thread.context.hart_index;
    const hart_id = proc.harts[hart_index].id;
    trap.plic.complete(hart_id, source);
    trap.enableInterrupts();
}

pub fn remove(thread: *Thread, source: u32) void {
    log.debug("Thread id={d} removing itself from interrupt source=0x{x}", .{ thread.id, source });
    const bucket = bucketOf(source);
    defer bucket.lock.unlock();

    var prev: ?*WaitReason = null;
    var curr: ?*WaitReason = bucket.head;
    const wait_reason = while (curr) |c| {
        // FIXME: check that this is the correct thread?
        if (c.payload.interrupt.source == source) {
            break c;
        }
        prev = c;
        curr = c.payload.interrupt.next;
    } else return;

    if (prev) |p| {
        p.payload.interrupt.next = wait_reason.payload.interrupt.next;
    } else {
        bucket.head = wait_reason.payload.interrupt.next;
    }
    const hart_index = thread.context.hart_index;
    const hart_id = proc.harts[hart_index].id;
    trap.plic.disable(hart_id, source);
}

fn bucketOf(source: u32) *Bucket {
    const hash = Wyhash.hash(0, mem.asBytes(&source));
    const bucket = &buckets[hash % bucket_count];
    bucket.lock.lock();
    return bucket;
}
