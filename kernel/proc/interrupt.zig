const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.@"proc.interrupt");
const Wyhash = std.hash.Wyhash;
const riscv = @import("../riscv.zig");
const trap = @import("../trap.zig");
const proc = @import("../proc.zig");
const Process = proc.Process;
const WaitReason = Process.WaitReason;
const Hart = proc.Hart;
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;

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

pub fn wait(process: *Process, source: u32) !void {
    const bucket = bucketOf(source);
    defer bucket.lock.unlock();

    const wait_reason = try process.waitReasonAllocate();
    wait_reason.payload = .{ .interrupt = .{ .source = source, .next = null } };
    log.debug("Process id={d} waiting on interrupt source=0x{x}", .{ process.id, source });

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

    const hart_index = process.context.hart_index;
    const hart_id = proc.harts[hart_index].id;
    trap.plic.setPriority(source, 1);
    trap.plic.enable(hart_id, source);

    // FIXME: This is pretty bad. Force PLIC to re-evaluate.
    // Needed in case this interrupt was pending before enabling.
    trap.plic.setTreshold(hart_id, 0);
}

pub fn check(process: ?*Process, idle_hart_index: Hart.Index) noreturn {
    const hart_index = if (process) |p| p.context.hart_index else idle_hart_index;
    const hart_id = proc.harts[hart_index].id;
    const source = trap.plic.claim(hart_id);

    const bucket = bucketOf(source);

    outer: while (true) {
        var prev: ?*WaitReason = null;
        var curr: ?*WaitReason = bucket.head;
        while (curr) |c| {
            const owner = proc.processFromWaitReason(c);
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

            log.debug("Process id={d} received interrupt source=0x{x}", .{ owner.id, source });
            if (prev) |p| {
                p.payload.interrupt.next = c.payload.interrupt.next;
            } else {
                bucket.head = c.payload.interrupt.next;
            }
            owner.waitComplete(c, 0);
            trap.plic.disable(hart_id, source);
            trap.disableInterrupts();
            bucket.lock.unlock();
            proc.scheduler.schedule(process, owner, hart_index);
        }
        @panic("no interrupt handler");
    }
}

pub fn complete(process: *Process, source: u32) usize {
    log.debug("Process id={d} completed interrupt source=0x{x}", .{ process.id, source });
    const hart_index = process.context.hart_index;
    const hart_id = proc.harts[hart_index].id;
    trap.plic.complete(hart_id, source);
    trap.enableInterrupts();
    return 0;
}

pub fn remove(process: *Process, source: u32) void {
    log.debug("Process id={d} removing itself from interrupt source=0x{x}", .{ process.id, source });
    const bucket = bucketOf(source);
    defer bucket.lock.unlock();

    var prev: ?*WaitReason = null;
    var curr: ?*WaitReason = bucket.head;
    while (curr) |c| {
        if (c.payload.interrupt.source == source) {
            if (prev) |p| {
                p.payload.interrupt.next = c.payload.interrupt.next;
            } else {
                bucket.head = c.payload.interrupt.next;
            }
            const hart_index = process.context.hart_index;
            const hart_id = proc.harts[hart_index].id;
            trap.plic.disable(hart_id, source);
            c.completed = false;
            c.result = 0;
            c.payload = .{ .none = {} };
            break;
        }
        prev = c;
        curr = c.payload.interrupt.next;
    }
}

fn bucketOf(source: u32) *Bucket {
    const hash = Wyhash.hash(0, mem.asBytes(&source));
    const bucket = &buckets[hash % bucket_count];
    bucket.lock.lock();
    return bucket;
}
