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
const Futex = @This();

lock: Spinlock,
address: PhysicalAddress,
head: ?*WaitReason,
tail: ?*WaitReason,
next: ?*Futex,

const Bucket = ?*Futex;
const futex_count = 32;
const bucket_count = 32;

var futeces: [futex_count]Futex = undefined;
var free_list_head: ?*Futex = undefined;
var free_list_lock: Spinlock = .{};
var buckets: [bucket_count]Bucket = undefined;
var buckets_lock: Spinlock = .{};

pub fn init() void {
    for (&buckets) |*bucket| {
        bucket.* = null;
    }
    var prev: ?*Futex = null;
    for ((&futeces)[1..]) |*futex| {
        futex.lock = .{};
        futex.address = 0;
        futex.head = null;
        futex.tail = null;
        futex.next = prev;
        prev = futex;
    }
    free_list_head = prev;
}

pub fn wait(process: *Process, virtual_address: UserVirtualAddress, expected_value: u32) !void {
    if (virtual_address >= mm.user_virtual_end)
        return error.InvalidParameter;
    if (!mem.isAligned(virtual_address, @alignOf(u32)))
        return error.InvalidParameter;
    if (virtual_address == 0)
        return error.InvalidParameter;

    const physical_address = process.page_table.translate(virtual_address) catch return error.InvalidParameter;
    const futex = try futexOf(physical_address, true);
    defer futex.lock.unlock();
    errdefer if (futex.isEmpty())
        futex.free();

    const actual_value = @as(*u32, @ptrFromInt(virtual_address)).*;
    if (actual_value != expected_value)
        return error.WouldBlock;

    try futex.append(process);
}

pub fn wake(process: *Process, virtual_address: UserVirtualAddress, count: usize) !usize {
    if (virtual_address >= mm.user_virtual_end)
        return error.InvalidParameter;
    if (!mem.isAligned(virtual_address, @alignOf(u32)))
        return error.InvalidParameter;
    if (count == 0)
        return error.InvalidParameter;

    const physical_address = process.page_table.translate(virtual_address) catch return error.InvalidParameter;

    // FIXME: Maybe unlock process while popping waiters from the queue?
    const futex = futexOf(physical_address, false) catch return 0;
    defer futex.lock.unlock();

    return futex.pop(count);
}

pub fn remove(self: *Futex, process: *Process) void {
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
            if (self.isEmpty())
                self.free();
            c.completed = false;
            c.result = 0;
            c.payload = .{ .none = {} };
            break;
        }

        prev = c;
        curr = c.payload.futex.next;
    }
}

fn bucketOf(address: PhysicalAddress) *Bucket {
    const hash = Wyhash.hash(0, mem.asBytes(&address));
    const bucket = &buckets[hash % bucket_count];
    buckets_lock.lock();
    return bucket;
}

fn futexOf(address: PhysicalAddress, allocate: bool) !*Futex {
    const bucket = bucketOf(address);
    defer buckets_lock.unlock();

    var futex: ?*Futex = bucket.*;
    while (futex) |ftx| : (futex = ftx.next) {
        ftx.lock.lock();
        if (ftx.address == address)
            return ftx;
        ftx.lock.unlock();
    }

    if (!allocate)
        return error.Exists;

    free_list_lock.lock();
    defer free_list_lock.unlock();

    if (free_list_head) |head| {
        free_list_head = head.next;
        head.next = bucket.*;
        bucket.* = head;
        head.lock.lock();
        return head;
    }
    return error.OutOfMemory;
}

fn append(self: *Futex, process: *Process) !void {
    const wait_reason = try process.waitReasonAllocate();
    wait_reason.payload = .{ .futex = .{ .futex = self, .next = null } };

    if (self.tail) |tail| {
        tail.payload.futex.next = wait_reason;
    } else {
        self.head = wait_reason;
    }
    self.tail = wait_reason;
}

fn pop(self: *Futex, count: usize) usize {
    defer if (self.isEmpty())
        self.free();

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

fn isEmpty(self: *Futex) bool {
    return self.head == null;
}

fn free(self: *Futex) void {
    const bucket = bucketOf(self.address);
    var prev: ?*Futex = null;
    var curr: ?*Futex = bucket.*;
    while (curr) |c| {
        if (c.address == self.address) {
            if (prev) |p| {
                p.next = self.next;
            } else {
                bucket.* = self.next;
            }
            break;
        }
        prev = c;
        curr = c.next;
    }
    buckets_lock.unlock();

    free_list_lock.lock();
    self.next = free_list_head;
    free_list_head = self;
    free_list_lock.unlock();
}
