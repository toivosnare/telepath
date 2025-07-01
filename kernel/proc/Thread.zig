const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"proc.Thread");
const mem = std.mem;
const sbi = @import("sbi");
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;
const Handle = libt.Handle;
const mm = @import("../mm.zig");
const PhysicalAddress = mm.PhysicalAddress;
const VirtualAddress = mm.VirtualAddress;
const proc = @import("../proc.zig");
const scheduler = proc.scheduler;
const Process = proc.Process;
const Capability = proc.Capability;
const Thread = @This();

lock: Spinlock,
ref_count: usize,
id: Id,
process: *Process,
state: State,
context: Context,
priority: scheduler.Priority,
scheduler_next: ?*Thread,
waiters_head: ?*WaitNode,
exit_code: usize,
wait_nodes: [max_wait_nodes]WaitNode,
wait_events: []libt.syscall.WaitEvent,
wait_timeout_next: ?*Thread,
wait_timeout_time: u64,

const max_wait_nodes = 16;

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

pub const WaitNode = struct {
    result: ?usize,
    payload: union(Tag) {
        none: void,
        futex: struct {
            address: PhysicalAddress,
            next: ?*WaitNode,
        },
        thread: struct {
            thread: *Thread,
            next: ?*WaitNode,
        },
        interrupt: struct {
            source: u32,
            next: ?*WaitNode,
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
        .ready => scheduler.remove(self),
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
        .ready => scheduler.remove(self),
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
        var wait_node: ?*WaitNode = self.waiters_head;
        while (wait_node) |wn| : (wait_node = wn.payload.thread.next) {
            const owner = proc.threadFromWaitNode(wn);
            if (!owner.lock.tryLock()) {
                self.lock.unlock();
                // Add some delay.
                for (0..10) |i|
                    mem.doNotOptimizeAway(i);
                self.lock.lock();
                continue :outer;
            }
            defer owner.lock.unlock();

            assert(wn.payload.thread.thread == self);

            // log.debug("Thread id={d} received interrupt source=0x{x}", .{ owner.id, source });
            owner.waitComplete(wn, exit_code);
            scheduler.enqueue(owner);
        }
        break :outer;
    }
}

pub fn synchronize(self: *Thread, signals: []libt.syscall.WakeSignal, events: []libt.syscall.WaitEvent, timeout_us: usize) !usize {
    if (events.len > max_wait_nodes)
        return error.InvalidParameter;

    // TODO: Make sure reading the signal fields do not trap.
    var waken_thread_count: usize = 0;
    for (signals) |signal|
        waken_thread_count += try proc.Futex.wake(self, @intFromPtr(signal.address), signal.count);

    defer {
        self.waitRemove();
        self.waitClear();
        wakeHarts(waken_thread_count);
    }

    // TODO: Make sure reading the event fields do not trap.
    self.wait_events = events;
    for (0.., self.wait_events, self.waitNodes()) |event_index, *event, *node| {
        node.result = null;
        node.payload = .{ .none = {} };

        const result_or_error = if (event.tag == .futex) blk: {
            const virtual_address = @intFromPtr(event.payload.futex.address);
            const expected_value = event.payload.futex.expected_value;
            break :blk proc.Futex.wait(self, node, virtual_address, expected_value);
        } else if (event.tag == .thread) blk: {
            const thread_handle = event.payload.thread;
            break :blk self.waitThread(node, thread_handle);
        } else if (event.tag == .interrupt) blk: {
            const source = event.payload.interrupt;
            break :blk self.waitInterrupt(node, source);
        } else blk: {
            break :blk error.InvalidParameter;
        };
        if (result_or_error) |res| {
            if (res) |r| {
                event.result = r;
                return event_index;
            }
        } else |err| {
            event.result = libt.syscall.packResult(err);
            return event_index;
        }
    }

    if (timeout_us == 0) {
        if (events.len == 0)
            return waken_thread_count;

        return error.Timeout;
    }

    proc.timeout.wait(self, timeout_us);
    self.state = .waiting;
    const hart_index = self.context.hart_index;
    self.lock.unlock();

    // One of the waken threads can be run on this hart so do not wake up an extra hart.
    wakeHarts(waken_thread_count -| 1);

    log.debug("Thread id={d} is waiting with {d} events", .{ self.id, events.len });
    scheduler.scheduleNext(null, hart_index);
}

fn wakeHarts(max_amount: usize) void {
    var amount: usize = 0;
    var hart_mask: usize = 0;
    for (proc.harts) |*hart| {
        if (amount == max_amount)
            break;
        if (hart.idling) {
            hart.idling = false;
            hart_mask |= @as(usize, 1) << @intCast(hart.id);
            amount += 1;
        }
    }
    if (amount != 0) {
        sbi.ipi.sendIPI(.{ .mask = .{
            .mask = hart_mask,
            .base = 0,
        } }) catch @panic("sending an IPI failed");
    }
}

fn waitThread(self: *Thread, wait_node: *WaitNode, thread_handle: Handle) !?usize {
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

    wait_node.payload = .{ .thread = .{ .thread = thread, .next = thread.waiters_head } };
    thread.waiters_head = wait_node;
    return null;
}

fn waitInterrupt(self: *Thread, wait_node: *WaitNode, source: u32) ?usize {
    log.debug("Thread id={d} waiting on interrupt source=0x{x}", .{ self.id, source });
    const hart_index = self.context.hart_index;
    wait_node.payload = .{ .interrupt = .{ .source = source, .next = null } };
    proc.interrupt.wait(wait_node, source, hart_index);
    return null;
}

pub fn waitComplete(self: *Thread, wait_node: *WaitNode, result: usize) void {
    log.debug("WaitNode of Thread id={d} is complete", .{self.id});
    assert(proc.threadFromWaitNode(wait_node) == self);
    wait_node.result = result;
    self.waitRemove();
    proc.timeout.remove(self);
}

fn waitThreadRemove(self: *Thread, waitee: *Thread) void {
    var prev: ?*WaitNode = null;
    var curr: ?*WaitNode = waitee.waiters_head;
    const wait_node = while (curr) |c| {
        if (proc.threadFromWaitNode(c) == self) {
            break c;
        }
        prev = c;
        curr = c.payload.thread.next;
    } else return;

    if (prev) |p| {
        p.payload.thread.next = wait_node.payload.thread.next;
    } else {
        waitee.waiters_head = wait_node.payload.thread.next;
    }
}

pub fn waitRemove(self: *Thread) void {
    log.debug("Thread id={d} clearing WaitNodes", .{self.id});
    for (self.waitNodes()) |*wait_node| {
        if (wait_node.result) |_|
            continue;
        switch (wait_node.payload) {
            .none => {},
            .futex => proc.Futex.remove(self, wait_node.payload.futex.address),
            .thread => waitThreadRemove(self, wait_node.payload.thread.thread),
            .interrupt => proc.interrupt.remove(self, wait_node.payload.interrupt.source),
        }
    }
}

pub fn waitCopyResult(self: *Thread) void {
    log.debug("Thread id={d} copying wait result to user", .{self.id});

    for (0.., self.waitNodes(), self.wait_events) |index, *node, *event| {
        if (node.result) |r| {
            event.result = r;
            self.context.a0 = index;
            break;
        }
    }
    self.waitClear();
}

pub fn waitClear(self: *Thread) void {
    log.debug("Thread id={d} clearing wait state", .{self.id});
    for (&self.wait_nodes) |*wait_node| {
        wait_node.result = null;
        wait_node.payload = .{ .none = {} };
    }
    self.wait_events = &.{};
    self.wait_timeout_next = null;
    self.wait_timeout_time = 0;
}

fn waitNodes(self: *Thread) []WaitNode {
    return (&self.wait_nodes)[0..self.wait_events.len];
}

pub fn ack(self: *Thread, source: u32) void {
    proc.interrupt.complete(self, source);
}

pub fn handlePageFault(self: *Thread, faulting_address: VirtualAddress, kind: Process.PageFaultKind) noreturn {
    if (self.process.handlePageFault(faulting_address, kind)) {
        scheduler.scheduleCurrent(self);
    } else {
        self.exit(libt.syscall.packResult(error.Crashed));
        self.lock.unlock();
        scheduler.scheduleNext(null, self.context.hart_index);
    }
}
