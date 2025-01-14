const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"proc.Thread");
const mem = std.mem;
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;
const Handle = libt.Handle;
const mm = @import("../mm.zig");
const PhysicalAddress = mm.PhysicalAddress;
const VirtualAddress = mm.VirtualAddress;
const proc = @import("../proc.zig");
const Process = proc.Process;
const Capability = proc.Capability;
const Thread = @This();

lock: Spinlock,
ref_count: usize,
id: Id,
process: *Process,
state: State,
context: Context,
scheduler_next: ?*Thread,
waiters_head: ?*WaitReason,
exit_code: usize,
wait_reason_count: usize,
wait_reasons: [max_wait_reasons]WaitReason,
wait_reasons_user: []libt.syscall.WaitReason,
wait_timeout_next: ?*Thread,
wait_timeout_time: u64,

const max_wait_reasons = 8;

pub const Id = usize;

pub const State = enum {
    invalid,
    ready,
    waiting,
    running,
    exited,
};

pub const Context = extern struct {
    pc: usize,
    ra: usize,
    sp: usize,
    gp: usize,
    tp: usize,
    t0: usize,
    t1: usize,
    t2: usize,
    s0: usize,
    s1: usize,
    a0: usize,
    a1: usize,
    a2: usize,
    a3: usize,
    a4: usize,
    a5: usize,
    a6: usize,
    a7: usize,
    s2: usize,
    s3: usize,
    s4: usize,
    s5: usize,
    s6: usize,
    s7: usize,
    s8: usize,
    s9: usize,
    s10: usize,
    s11: usize,
    t3: usize,
    t4: usize,
    t5: usize,
    t6: usize,
    hart_index: proc.Hart.Index,

    pub fn thread(self: *Context) *Thread {
        return @fieldParentPtr("context", self);
    }
};

pub const WaitReason = struct {
    completed: bool,
    result: usize,
    payload: union(Tag) {
        none: void,
        futex: struct {
            address: PhysicalAddress,
            next: ?*WaitReason,
        },
        thread: struct {
            thread: *Thread,
            next: ?*WaitReason,
        },
        interrupt: struct {
            source: u32,
            next: ?*WaitReason,
        },
    },

    pub const Tag = enum {
        none,
        futex,
        thread,
        interrupt,
    };
};

pub fn ref(self: *Thread) void {
    self.lock.lock();
    self.ref_count += 1;
    self.lock.unlock();
}

pub fn unref(self: *Thread) void {
    self.lock.lock();
    defer self.lock.unlock();

    self.ref_count -= 1;
    if (self.ref_count > 0)
        return;

    switch (self.state) {
        .invalid => unreachable,
        .ready => proc.scheduler.remove(self),
        .waiting => {
            self.waitRemove();
            proc.timeout.remove(self);
        },
        .running => return,
        .exited => {},
    }
    // TODO: free capabilities.
    proc.freeThread(self);
}

pub fn die(self: *Thread, exit_code: usize) void {
    switch (self.state) {
        .invalid => unreachable,
        .ready => proc.scheduler.remove(self),
        .waiting => {
            self.waitRemove();
            proc.timeout.remove(self);
        },
        .running => {},
        .exited => return,
    }
    self.exit(exit_code);
}

pub fn exit(self: *Thread, exit_code: usize) void {
    if (self.state == .exited)
        return;

    self.state = .exited;
    self.exit_code = exit_code;

    outer: while (true) {
        var wait_reason: ?*WaitReason = self.waiters_head;
        while (wait_reason) |wr| : (wait_reason = wr.payload.thread.next) {
            const owner = proc.threadFromWaitReason(wr);
            if (!owner.lock.tryLock()) {
                self.lock.unlock();
                // Add some delay.
                for (0..10) |i|
                    mem.doNotOptimizeAway(i);
                self.lock.lock();
                continue :outer;
            }
            defer owner.lock.unlock();

            assert(wr.payload.thread.thread == self);

            // log.debug("Thread id={d} received interrupt source=0x{x}", .{ owner.id, source });
            owner.waitComplete(wr, exit_code);
            proc.scheduler.enqueue(owner);
        }
        break :outer;
    }
}

pub fn wait(self: *Thread, reasons: []libt.syscall.WaitReason, timeout_us: usize) !usize {
    if (reasons.len > max_wait_reasons)
        return error.InvalidParameter;

    for (0.., reasons) |index, *reason| {
        const wait_reason = self.waitReasonAllocate() catch |err| {
            self.waitRemove();
            self.waitClear();
            return err;
        };

        const result_or_error = if (reason.tag == .futex) blk: {
            const virtual_address = @intFromPtr(reason.payload.futex.address);
            const expected_value = reason.payload.futex.expected_value;
            break :blk self.waitFutex(wait_reason, virtual_address, expected_value);
        } else if (reason.tag == .thread) blk: {
            const thread_handle = reason.payload.thread;
            break :blk self.waitThread(wait_reason, thread_handle);
        } else if (reason.tag == .interrupt) blk: {
            const source = reason.payload.interrupt;
            break :blk self.waitInterrupt(wait_reason, source);
        } else blk: {
            break :blk error.InvalidParameter;
        };
        if (result_or_error) |res| {
            if (res) |r| {
                reason.result = r;
                self.waitRemove();
                return index;
            }
        } else |err| {
            reason.result = libt.syscall.packResult(err);
            self.waitRemove();
            return index;
        }
    }
    self.wait_reasons_user = reasons;

    proc.timeout.wait(self, timeout_us);
    self.state = .waiting;

    log.debug("Thread id={d} is waiting with {d} reasons", .{ self.id, reasons.len });

    self.lock.unlock();
    proc.scheduler.scheduleNext(null, self.context.hart_index);
}

fn waitReasonAllocate(self: *Thread) !*WaitReason {
    if (self.wait_reason_count == max_wait_reasons) {
        log.warn("Thread id={d} has no free wait reasons", .{self.id});
        return error.OutOfMemory;
    }

    const wait_reason = &self.wait_reasons[self.wait_reason_count];
    wait_reason.completed = false;
    wait_reason.result = 0;
    wait_reason.payload = .{ .none = {} };
    self.wait_reason_count += 1;
    return wait_reason;
}

fn waitFutex(self: *Thread, wait_reason: *WaitReason, virtual_address: VirtualAddress, expected_value: u32) !?usize {
    if (virtual_address >= mm.user_virtual_end) {
        log.warn("Thread id={d} tried to wait on address=0x{x} which is outside user address space", .{ self.id, virtual_address });
        return error.InvalidParameter;
    }
    if (!mem.isAligned(virtual_address, @alignOf(u32))) {
        log.warn("Thread id={d} tried to wait on address=0x{x} which not aligned to 4 bytes", .{ self.id, virtual_address });
        return error.InvalidParameter;
    }
    if (virtual_address == 0) {
        log.warn("Thread id={d} tried to wait on address=0x0", .{self.id});
        return error.InvalidParameter;
    }

    const physical_address = self.process.page_table.translate(virtual_address) catch {
        log.warn("Thread id={d} tried to wait on address=0x{x} which is not mapped", .{ self.id, virtual_address });
        return error.InvalidParameter;
    };

    const ptr = @as(*u32, @ptrFromInt(virtual_address));
    const actual_value = ptr.*;
    if (actual_value != expected_value) {
        log.debug("Thread id={d} expected {*} to be {d} whereas the actual value is {d}", .{ self.id, ptr, expected_value, actual_value });
        return error.WouldBlock;
    }

    log.debug("Thread id={d} waiting on Futex address=0x{x}", .{ self.id, physical_address });
    wait_reason.payload = .{ .futex = .{ .address = physical_address, .next = null } };
    try proc.Futex.wait(wait_reason, physical_address);
    return null;
}

fn waitThread(self: *Thread, wait_reason: *WaitReason, thread_handle: Handle) !?usize {
    const thread = blk: {
        self.process.lock.lock();
        defer self.process.lock.unlock();

        const thread_capability = try Capability.get(thread_handle, self.process);
        break :blk try thread_capability.thread();
    };

    log.debug("Thread id={d} is waiting on Thread id={d}", .{ self.id, thread.id });
    // TODO: no need for locking?
    if (thread.state == .exited) {
        return self.exit_code;
    }

    wait_reason.payload = .{ .thread = .{ .thread = thread, .next = thread.waiters_head } };
    thread.waiters_head = wait_reason;
    return null;
}

fn waitInterrupt(self: *Thread, wait_reason: *WaitReason, source: u32) ?usize {
    log.debug("Thread id={d} waiting on interrupt source=0x{x}", .{ self.id, source });
    const hart_index = self.context.hart_index;
    wait_reason.payload = .{ .interrupt = .{ .source = source, .next = null } };
    proc.interrupt.wait(wait_reason, source, hart_index);
    return null;
}

pub fn waitComplete(self: *Thread, wait_reason: *WaitReason, result: usize) void {
    log.debug("WaitReason of Thread id={d} is complete", .{self.id});
    wait_reason.completed = true;
    wait_reason.result = result;
    self.waitRemove();
    proc.timeout.remove(self);
}

fn waitThreadRemove(self: *Thread, waitee: *Thread) void {
    var prev: ?*WaitReason = null;
    var curr: ?*WaitReason = waitee.waiters_head;
    const wait_reason = while (curr) |c| {
        if (proc.threadFromWaitReason(c) == self) {
            break c;
        }
        prev = c;
        curr = c.payload.thread.next;
    } else return;

    if (prev) |p| {
        p.payload.thread.next = wait_reason.payload.thread.next;
    } else {
        waitee.waiters_head = wait_reason.payload.thread.next;
    }
}

pub fn waitRemove(self: *Thread) void {
    log.debug("Thread id={d} clearing WaitReasons", .{self.id});
    for (self.waitReasons()) |*wait_reason| {
        if (wait_reason.completed)
            continue;
        switch (wait_reason.payload) {
            .none => @panic("removing empty WaitReason"),
            .futex => proc.Futex.remove(self, wait_reason.payload.futex.address),
            .thread => waitThreadRemove(self, wait_reason.payload.thread.thread),
            .interrupt => proc.interrupt.remove(self, wait_reason.payload.interrupt.source),
        }
        // wait_reason.completed = false;
        // wait_reason.result = 0;
        // wait_reason.payload = .{ .none = {} };
    }
}

pub fn waitCopyResult(self: *Thread) void {
    if (self.wait_reason_count == 0)
        return;
    log.debug("Thread id={d} copying wait result to user", .{self.id});

    for (0.., self.waitReasons(), self.wait_reasons_user) |index, *kernel, *user| {
        if (kernel.completed) {
            user.result = kernel.result;
            self.context.a0 = index;
            break;
        }
    }
    self.waitClear();
}

pub fn waitClear(self: *Thread) void {
    log.debug("Thread id={d} clearing wait state", .{self.id});
    self.wait_reason_count = 0;
    for (&self.wait_reasons) |*wait_reason| {
        wait_reason.completed = false;
        wait_reason.result = 0;
        wait_reason.payload = .{ .none = {} };
    }
    self.wait_reasons_user = undefined;
    self.wait_timeout_next = null;
    self.wait_timeout_time = 0;
}

fn waitReasons(self: *Thread) []WaitReason {
    return (&self.wait_reasons)[0..self.wait_reason_count];
}

pub fn wake(self: *Thread, virtual_address: VirtualAddress, waiter_count: usize) !usize {
    // FIXME: Maybe unlock self while popping waiters from the queue?
    if (virtual_address >= mm.user_virtual_end) {
        log.warn("Thread id={d} tried to wake on address=0x{x} which is outside user address space", .{ self.id, virtual_address });
        return error.InvalidParameter;
    }
    if (!mem.isAligned(virtual_address, @alignOf(u32))) {
        log.warn("Thread id={d} tried to wake on address=0x{x} which not aligned to 4 bytes", .{ self.id, virtual_address });
        return error.InvalidParameter;
    }
    if (virtual_address == 0) {
        log.warn("Thread id={d} tried to wake on address=0x0", .{self.id});
        return error.InvalidParameter;
    }
    if (waiter_count == 0) {
        log.warn("Thread id={d} tried to wake 0 waiters", .{self.id});
        return error.InvalidParameter;
    }
    const physical_address = self.process.page_table.translate(virtual_address) catch {
        log.warn("Thread id={d} tried to wake on address=0x{x} which is not mapped", .{ self.id, virtual_address });
        return error.InvalidParameter;
    };

    log.debug("Thread id={d} is waking {d} waiters waiting on Futex address=0x{x}", .{ self.id, waiter_count, physical_address });
    return proc.Futex.wake(physical_address, waiter_count);
}

pub fn ack(self: *Thread, source: u32) void {
    proc.interrupt.complete(self, source);
}

pub fn handlePageFault(self: *Thread, faulting_address: VirtualAddress, kind: Process.PageFaultKind) noreturn {
    if (self.process.handlePageFault(faulting_address, kind)) {
        proc.scheduler.scheduleCurrent(self);
    } else {
        self.exit(libt.syscall.packResult(error.Crashed));
        self.lock.unlock();
        proc.scheduler.scheduleNext(null, self.context.hart_index);
    }
}
