const std = @import("std");
const mem = std.mem;
const Wyhash = std.hash.Wyhash;
const mm = @import("../mm.zig");
const PhysicalAddress = mm.PhysicalAddress;
const UserVirtualAddress = mm.UserVirtualAddress;
const proc = @import("../proc.zig");
const Process = proc.Process;
const WaitReason = Process.WaitReason;
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;

pub const WaitQueue = struct {
    lock: Spinlock,
    address: PhysicalAddress,
    head: ?*WaitReason,
    tail: ?*WaitReason,
    next: ?*WaitQueue,

    const capacity = 32;
    var queues: [capacity]WaitQueue = undefined;
    var head: ?*WaitQueue = undefined;
    var lock: Spinlock = .{};

    pub fn init() void {
        var prev: ?*WaitQueue = null;
        for ((&queues)[1..]) |*wait_queue| {
            wait_queue.lock = .{};
            wait_queue.address = 0;
            wait_queue.head = null;
            wait_queue.tail = null;
            wait_queue.next = prev;
            prev = wait_queue;
        }
        head = prev;
    }

    pub fn allocate() !*WaitQueue {
        lock.lock();
        defer lock.unlock();

        if (head) |h| {
            head = h.next;
            return h;
        }
        return error.OutOfMemory;
    }

    pub fn append(self: *WaitQueue, process: *Process) !void {
        const wait_reason = try process.waitReasonAllocate();
        wait_reason.payload = .{ .futex = .{ .queue = self, .next = null } };

        if (self.tail) |tail| {
            tail.payload.futex.next = wait_reason;
        } else {
            self.head = wait_reason;
        }
        self.tail = wait_reason;
    }

    pub fn pop(self: *WaitQueue, count: usize) usize {
        var result: usize = 0;
        while (result < count) {
            if (self.head) |wait_reason| {
                const process = proc.processFromWaitReason(wait_reason);
                if (!process.lock.tryLock()) {
                    self.lock.unlock();
                    // Add some delay.
                    for (0..10) |i|
                        mem.doNotOptimizeAway(i);
                    self.lock.lock();
                    continue;
                }
                self.head = wait_reason.payload.futex.next;
                if (wait_reason == self.tail)
                    self.tail = null;
                wait_reason.payload.futex.next = null;
                wait_reason.completed = true;
                wait_reason.result = 0;
                process.waitCheck();
                result += 1;
                process.lock.unlock();
            } else {
                return result;
            }
        }
        return count;
    }

    pub fn remove(self: *WaitQueue, process: *Process) void {
        var prev: ?*WaitReason = null;
        var curr: ?*WaitReason = self.head;
        while (curr) |c| {
            if (proc.processFromWaitReason(c) == process) {
                if (prev) |p| {
                    p.payload.futex.next = c.payload.futex.next;
                } else {
                    self.head = c.payload.futex.next;
                }
                if (c == self.tail)
                    self.tail = null;
                c.completed = false;
                c.result = 0;
                c.payload = .{ .none = {} };
                break;
            }

            prev = c;
            curr = c.payload.futex.next;
        }
    }

    pub fn isEmpty(self: *WaitQueue) bool {
        return self.head == null;
    }

    pub fn free(wait_queue: *WaitQueue) void {
        lock.lock();
        wait_queue.next = head;
        head = wait_queue;
        lock.unlock();
    }
};

const bucket_count = 32;
var buckets: [bucket_count]?*WaitQueue = undefined;
var buckets_lock: Spinlock = .{};

pub fn init() void {
    for (&buckets) |*bucket| {
        bucket.* = null;
    }
    WaitQueue.init();
}

// process.lock must be held, i think?
pub fn wait(process: *Process, virtual_address: UserVirtualAddress, expected_value: u32) !void {
    if (virtual_address >= mm.user_virtual_end)
        return error.InvalidParameter;
    if (!mem.isAligned(virtual_address, @alignOf(u32)))
        return error.InvalidParameter;
    if (virtual_address == 0)
        return error.InvalidParameter;

    const physical_address = process.page_table.translate(virtual_address) catch return error.InvalidParameter;
    const wait_queue = try findWaitQueueForAddress(physical_address);
    defer wait_queue.lock.unlock();

    const actual_value = @as(*u32, @ptrFromInt(virtual_address)).*;
    if (actual_value != expected_value)
        return error.WouldBlock;

    try wait_queue.append(process);
}

pub fn wake(process: *Process, virtual_address: UserVirtualAddress, count: usize) !usize {
    if (virtual_address >= mm.user_virtual_end)
        return error.InvalidParameter;
    if (!mem.isAligned(virtual_address, @alignOf(u32)))
        return error.InvalidParameter;
    if (count == 0)
        return error.InvalidParameter;

    process.lock.lock();
    const physical_address = blk: {
        defer process.lock.unlock();
        break :blk process.page_table.translate(virtual_address) catch return error.InvalidParameter;
    };

    const hash = Wyhash.hash(0, mem.asBytes(&physical_address));
    const bucket = &buckets[hash % bucket_count];

    buckets_lock.lock();
    defer buckets_lock.unlock();

    var prev: ?*WaitQueue = null;
    var current: ?*WaitQueue = bucket.*;
    while (current) |wq| {
        wq.lock.lock();
        if (wq.address == physical_address)
            break;
        wq.lock.unlock();
        prev = current;
        current = wq.next;
    } else {
        return 0;
    }
    const wait_queue = current.?;

    const waken_count = wait_queue.pop(count);
    if (wait_queue.isEmpty()) {
        if (prev) |p| {
            p.next = wait_queue.next;
        } else {
            bucket.* = wait_queue.next;
        }
        wait_queue.free();
    }
    wait_queue.lock.unlock();
    return waken_count;
}

fn findWaitQueueForAddress(address: PhysicalAddress) !*WaitQueue {
    const hash = Wyhash.hash(0, mem.asBytes(&address));
    const bucket = &buckets[hash % bucket_count];

    buckets_lock.lock();
    defer buckets_lock.unlock();

    var wait_queue: ?*WaitQueue = bucket.*;
    while (wait_queue) |wq| : (wait_queue = wq.next) {
        wq.lock.lock();
        if (wq.address == address)
            return wq;
        wq.lock.unlock();
    }

    const new_wait_queue = try WaitQueue.allocate();
    new_wait_queue.next = bucket.*;
    bucket.* = new_wait_queue;
    new_wait_queue.lock.lock();
    return new_wait_queue;
}
