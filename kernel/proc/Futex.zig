const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.@"proc.Futex");
const Wyhash = std.hash.Wyhash;
const mm = @import("../mm.zig");
const PhysicalAddress = mm.PhysicalAddress;
const UserVirtualAddress = mm.UserVirtualAddress;
const proc = @import("../proc.zig");
const Process = proc.Process;
const WaitReason = Process.WaitReason;
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;
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

pub fn wait(process: *Process, virtual_address: UserVirtualAddress, expected_value: u32) !void {
    if (virtual_address >= mm.user_virtual_end) {
        log.warn("Process id={d} tried to wait on address=0x{x} which is outside user address space", .{ process.id, virtual_address });
        return error.InvalidParameter;
    }
    if (!mem.isAligned(virtual_address, @alignOf(u32))) {
        log.warn("Process id={d} tried to wait on address=0x{x} which not aligned to 4 bytes", .{ process.id, virtual_address });
        return error.InvalidParameter;
    }
    if (virtual_address == 0) {
        log.warn("Process id={d} tried to wait on address=0x0", .{process.id});
        return error.InvalidParameter;
    }
    const physical_address = process.page_table.translate(virtual_address) catch {
        log.warn("Process id={d} tried to wait on address=0x{x} which is not mapped", .{ process.id, virtual_address });
        return error.InvalidParameter;
    };

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

    const ptr = @as(*u32, @ptrFromInt(virtual_address));
    const actual_value = ptr.*;
    if (actual_value != expected_value) {
        log.debug("Process id={d} expected {*} to be {d} whereas the actual value is {d}", .{ process.id, ptr, expected_value, actual_value });
        return error.WouldBlock;
    }

    const wait_reason = try process.waitReasonAllocate();
    wait_reason.payload = .{ .futex = .{ .address = physical_address, .next = null } };
    log.debug("Process id={d} waiting on Futex address=0x{x}", .{ process.id, physical_address });

    if (futex.tail) |tail| {
        tail.payload.futex.next = wait_reason;
    } else {
        futex.head = wait_reason;
    }
    futex.tail = wait_reason;
}

pub fn wake(process: *Process, virtual_address: UserVirtualAddress, count: usize) !usize {
    if (virtual_address >= mm.user_virtual_end) {
        log.warn("Process id={d} tried to wake on address=0x{x} which is outside user address space", .{ process.id, virtual_address });
        return error.InvalidParameter;
    }
    if (!mem.isAligned(virtual_address, @alignOf(u32))) {
        log.warn("Process id={d} tried to wake on address=0x{x} which not aligned to 4 bytes", .{ process.id, virtual_address });
        return error.InvalidParameter;
    }
    if (virtual_address == 0) {
        log.warn("Process id={d} tried to wake on address=0x0", .{process.id});
        return error.InvalidParameter;
    }
    if (count == 0) {
        log.warn("Process id={d} tried to wake 0 waiters", .{process.id});
        return error.InvalidParameter;
    }
    const physical_address = process.page_table.translate(virtual_address) catch {
        log.warn("Process id={d} tried to wake on address=0x{x} which is not mapped", .{ process.id, virtual_address });
        return error.InvalidParameter;
    };

    log.debug("Process id={d} is waking {d} waiters waiting on Futex address=0x{x}", .{ process.id, count, physical_address });

    // FIXME: Maybe unlock process while popping waiters from the queue?
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

            const p = proc.processFromWaitReason(wait_reason);
            if (!p.lock.tryLock()) {
                bucket.lock.unlock();
                // Add some delay.
                for (0..10) |i|
                    mem.doNotOptimizeAway(i);
                bucket.lock.lock();
                continue :outer;
            }
            defer p.lock.unlock();

            log.debug("Popped Process id={d} from Futex address=0x{x}", .{ process.id, physical_address });
            futex.head = wait_reason.payload.futex.next;
            wait_reason.payload.futex.next = null;
            wait_reason.completed = true;
            wait_reason.result = 0;
            p.waitCheck();
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

pub fn remove(process: *Process, physical_address: PhysicalAddress) void {
    log.debug("Process id={d} removing itself from the Futex address=0x{x}", .{ process.id, physical_address });
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
    while (curr_wait_reason) |curr| {
        if (proc.processFromWaitReason(curr) == process) {
            if (prev_wait_reason) |prev| {
                prev.payload.futex.next = curr.payload.futex.next;
            } else {
                futex.head = curr.payload.futex.next;
            }
            if (curr == futex.tail)
                futex.tail = null;
            futex.freeIfEmpty(bucket, prev_futex);
            curr.completed = false;
            curr.result = 0;
            curr.payload = .{ .none = {} };
            break;
        }

        prev_wait_reason = curr;
        curr_wait_reason = curr.payload.futex.next;
    }
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
