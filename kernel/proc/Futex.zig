const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.@"proc.Futex");
const Wyhash = std.hash.Wyhash;
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;
const mm = @import("../mm.zig");
const PhysicalAddress = mm.PhysicalAddress;
const proc = @import("../proc.zig");
const Thread = proc.Thread;
const WaitReason = Thread.WaitReason;
const Futex = @This();

address: PhysicalAddress,
head: ?*WaitReason,
tail: ?*WaitReason,
next: ?*Futex,

const Bucket = struct {
    lock: Spinlock,
    head: ?*Futex,
};

const futex_count = 32;
const bucket_count = 32;

var futeces: [futex_count]Futex = undefined;
var free_list_head: ?*Futex = undefined;
var free_list_lock: Spinlock = .{};
var buckets: [bucket_count]Bucket = undefined;

pub fn init() void {
    log.info("Initializing Futex subsystem", .{});
    for (&buckets) |*bucket| {
        bucket.lock = .{};
        bucket.head = null;
    }
    var prev: ?*Futex = null;
    for ((&futeces)[1..]) |*futex| {
        futex.address = 0;
        futex.head = null;
        futex.tail = null;
        futex.next = prev;
        prev = futex;
    }
    free_list_head = prev;
}

pub fn wait(wait_reason: *WaitReason, physical_address: PhysicalAddress) !void {
    const bucket = bucketOf(physical_address);
    defer bucket.lock.unlock();

    var prev: ?*Futex = null;
    var curr: ?*Futex = bucket.head;
    const futex = while (curr) |c| {
        if (c.address == physical_address)
            break c;
        prev = c;
        curr = c.next;
    } else try allocate(bucket, physical_address);

    errdefer futex.freeIfEmpty(bucket, prev);

    if (futex.tail) |tail| {
        tail.payload.futex.next = wait_reason;
    } else {
        futex.head = wait_reason;
    }
    futex.tail = wait_reason;
}

pub fn wake(physical_address: PhysicalAddress, count: usize) usize {
    const bucket = bucketOf(physical_address);
    defer bucket.lock.unlock();

    var result: usize = 0;
    outer: while (true) {
        var prev: ?*Futex = null;
        var curr: ?*Futex = bucket.head;
        const futex = while (curr) |c| {
            if (c.address == physical_address)
                break c;
            prev = c;
            curr = c.next;
        } else return result;

        while (result < count) {
            const wait_reason = futex.head orelse {
                futex.free(bucket, prev);
                return result;
            };

            const owner = proc.threadFromWaitReason(wait_reason);
            if (!owner.lock.tryLock()) {
                bucket.lock.unlock();
                // Add some delay.
                for (0..10) |i|
                    mem.doNotOptimizeAway(i);
                bucket.lock.lock();
                continue :outer;
            }
            defer owner.lock.unlock();

            log.debug("Popped Thread id={d} from Futex address=0x{x}", .{ owner.id, physical_address });
            futex.head = wait_reason.payload.futex.next;

            owner.waitComplete(wait_reason, 0);
            proc.scheduler.enqueue(owner);

            result += 1;
            if (wait_reason == futex.tail) {
                futex.tail = null;
                futex.free(bucket, prev);
                return result;
            }
        }
        futex.freeIfEmpty(bucket, prev);
        return count;
    }
}

pub fn remove(thread: *Thread, physical_address: PhysicalAddress) void {
    log.debug("Thread id={d} removing itself from the Futex address=0x{x}", .{ thread.id, physical_address });
    const bucket = bucketOf(physical_address);
    defer bucket.lock.unlock();

    var prev_futex: ?*Futex = null;
    var curr_futex: ?*Futex = bucket.head;
    const futex = while (curr_futex) |curr| {
        if (curr.address == physical_address)
            break curr;
        prev_futex = curr;
        curr_futex = curr.next;
    } else return;

    var prev_wait_reason: ?*WaitReason = null;
    var curr_wait_reason: ?*WaitReason = futex.head;
    const wait_reason = while (curr_wait_reason) |curr| {
        if (proc.threadFromWaitReason(curr) == thread) {
            break curr;
        }
        prev_wait_reason = curr;
        curr_wait_reason = curr.payload.futex.next;
    } else return;

    if (prev_wait_reason) |prev| {
        prev.payload.futex.next = wait_reason.payload.futex.next;
    } else {
        futex.head = wait_reason.payload.futex.next;
    }
    if (wait_reason == futex.tail)
        futex.tail = null;
    futex.freeIfEmpty(bucket, prev_futex);
}

fn bucketOf(address: PhysicalAddress) *Bucket {
    const hash = Wyhash.hash(0, mem.asBytes(&address));
    const bucket = &buckets[hash % bucket_count];
    bucket.lock.lock();
    return bucket;
}

fn allocate(bucket: *Bucket, address: PhysicalAddress) !*Futex {
    free_list_lock.lock();
    defer free_list_lock.unlock();

    if (free_list_head) |head| {
        log.debug("Allocating new Futex address=0x{x}", .{address});
        free_list_head = head.next;
        head.next = bucket.head;
        head.address = address;
        bucket.head = head;
        return head;
    } else {
        log.warn("Out of Futex memory", .{});
        return error.OutOfMemory;
    }
}

fn free(self: *Futex, bucket: *Bucket, prev: ?*Futex) void {
    log.debug("Freeing Futex address=0x{x}", .{self.address});

    if (prev) |p| {
        p.next = self.next;
    } else {
        bucket.head = self.next;
    }

    free_list_lock.lock();
    defer free_list_lock.unlock();

    self.next = free_list_head;
    free_list_head = self;
}

fn freeIfEmpty(self: *Futex, bucket: *Bucket, prev: ?*Futex) void {
    if (self.head == null) {
        self.free(bucket, prev);
    }
}
