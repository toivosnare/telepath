const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const log = std.log.scoped(.@"proc.Futex");
const Wyhash = std.hash.Wyhash;
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;
const mm = @import("../mm.zig");
const VirtualAddress = mm.VirtualAddress;
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

pub fn wait(thread: *Thread, wait_reason: *WaitReason, virtual_address: VirtualAddress, expected_value: u32) !?usize {
    if (virtual_address >= mm.user_virtual_end) {
        log.warn("Thread id={d} tried to wait on address=0x{x} which is outside user address space", .{ thread.id, virtual_address });
        return error.InvalidParameter;
    }
    if (!mem.isAligned(virtual_address, @alignOf(u32))) {
        log.warn("Thread id={d} tried to wait on address=0x{x} which not aligned to 4 bytes", .{ thread.id, virtual_address });
        return error.InvalidParameter;
    }
    if (virtual_address == 0) {
        log.warn("Thread id={d} tried to wait on address=0x0", .{thread.id});
        return error.InvalidParameter;
    }

    // TODO: Make sure the mapping is in the page table before trying to load the actual value.
    const physical_address = thread.process.page_table.translate(virtual_address) catch {
        log.warn("Thread id={d} tried to wait on address=0x{x} which is not mapped", .{ thread.id, virtual_address });
        return error.InvalidParameter;
    };

    const bucket = bucketOf(physical_address);
    bucket.lock.lock();
    defer bucket.lock.unlock();

    const ptr = @as(*u32, @ptrFromInt(virtual_address));
    const actual_value = ptr.*;
    if (actual_value != expected_value) {
        log.debug("Thread id={d} expected {*} to be {d} whereas the actual value is {d}", .{ thread.id, ptr, expected_value, actual_value });
        return error.WouldBlock;
    }

    log.debug("Thread id={d} waiting on Futex address=0x{x}", .{ thread.id, physical_address });

    var prev: ?*Futex = null;
    var curr: ?*Futex = bucket.head;
    const futex = while (curr) |c| {
        if (c.address == physical_address)
            break c;
        prev = c;
        curr = c.next;
    } else try allocate(bucket, physical_address);

    if (futex.tail) |tail| {
        tail.payload.futex.next = wait_reason;
    } else {
        futex.head = wait_reason;
    }
    futex.tail = wait_reason;

    wait_reason.payload = .{ .futex = .{ .address = physical_address, .next = null } };
    return null;
}

pub fn wake(thread: *Thread, virtual_address: VirtualAddress, count: usize) !usize {
    // FIXME: Maybe unlock self while popping waiters from the queue?
    if (count == 0)
        return 0;
    if (virtual_address >= mm.user_virtual_end) {
        log.warn("Thread id={d} tried to wake on address=0x{x} which is outside user address space", .{ thread.id, virtual_address });
        return error.InvalidParameter;
    }
    if (!mem.isAligned(virtual_address, @alignOf(u32))) {
        log.warn("Thread id={d} tried to wake on address=0x{x} which not aligned to 4 bytes", .{ thread.id, virtual_address });
        return error.InvalidParameter;
    }
    if (virtual_address == 0) {
        log.warn("Thread id={d} tried to wake on address=0x0", .{thread.id});
        return error.InvalidParameter;
    }
    const physical_address = thread.process.page_table.translate(virtual_address) catch {
        log.warn("Thread id={d} tried to wake on address=0x{x} which is not mapped", .{ thread.id, virtual_address });
        return error.InvalidParameter;
    };

    log.debug("Thread id={d} waking {d} waiters on Futex address=0x{x}", .{ thread.id, count, physical_address });
    const bucket = bucketOf(physical_address);

    var result: usize = 0;
    while (result < count) {
        bucket.lock.lock();
        var prev: ?*Futex = null;
        var curr: ?*Futex = bucket.head;
        const futex = while (curr) |c| {
            if (c.address == physical_address)
                break c;
            prev = c;
            curr = c.next;
        } else {
            bucket.lock.unlock();
            return result;
        };

        const event = futex.head orelse @panic("empty futex");
        const waiting_thread = proc.threadFromWaitReason(event);

        if (!waiting_thread.lock.tryLock()) {
            bucket.lock.unlock();
            // Add some delay.
            for (0..10) |i| mem.doNotOptimizeAway(i);
            continue;
        }

        log.debug("Popped Thread id={d} from Futex address=0x{x}", .{ waiting_thread.id, physical_address });

        futex.head = event.payload.futex.next;
        if (futex.tail == event) {
            futex.tail = null;
            assert(futex.head == null);
            futex.free(bucket, prev);
        }
        bucket.lock.unlock();

        waiting_thread.waitComplete(event, 0);
        proc.scheduler.enqueue(waiting_thread);
        waiting_thread.lock.unlock();

        result += 1;
    }
    return count;
}

pub fn remove(thread: *Thread, physical_address: PhysicalAddress) void {
    log.debug("Thread id={d} removing itself from the Futex address=0x{x}", .{ thread.id, physical_address });
    const bucket = bucketOf(physical_address);
    bucket.lock.lock();
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
    if (wait_reason == futex.tail) {
        if (prev_wait_reason) |prev| {
            futex.tail = prev;
        } else {
            futex.tail = null;
            assert(futex.head == null);
            futex.free(bucket, prev_futex);
        }
    }
}

fn bucketOf(address: PhysicalAddress) *Bucket {
    const hash = Wyhash.hash(0, mem.asBytes(&address));
    const bucket = &buckets[hash % bucket_count];
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
