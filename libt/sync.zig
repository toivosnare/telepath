const std = @import("std");
const atomic = std.atomic;
const math = std.math;
const libt = @import("libt.zig");
const syscall = libt.syscall;

pub const Mutex = extern struct {
    state: atomic.Value(u32) = atomic.Value(u32).init(unlocked),

    const unlocked: u32 = 0;
    const locked: u32 = 1;
    const contended: u32 = 2;

    pub fn lock(self: *Mutex) void {
        if (!self.tryLock())
            self.lockSlow();
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.state.cmpxchgWeak(unlocked, locked, .acquire, .monotonic) == null;
    }

    fn lockSlow(self: *Mutex) void {
        @setCold(true);

        while (self.state.swap(contended, .acquire) != unlocked) {
            libt.waitFutex(&self.state, contended, math.maxInt(usize)) catch |err| switch (err) {
                error.WouldBlock => {},
                else => unreachable,
            };
        }
    }

    pub fn unlock(self: *Mutex) void {
        if (self.state.swap(unlocked, .release) == contended)
            _ = syscall.wake(&self.state, 1) catch unreachable;
    }
};

pub const Condvar = extern struct {
    state: atomic.Value(u32) = atomic.Value(u32).init(0),

    pub fn wait(self: *Condvar, mutex: *Mutex) void {
        const old_state = self.state.load(.monotonic);

        mutex.unlock();
        libt.waitFutex(&self.state, old_state, math.maxInt(usize)) catch |err| switch (err) {
            error.WouldBlock => {},
            else => unreachable,
        };
        mutex.lock();
    }

    pub fn notify(self: *Condvar, count: enum { one, all }) void {
        while (true) {
            const old_state = self.state.load(.monotonic);
            const new_state = old_state + 1;
            if (self.state.cmpxchgWeak(old_state, new_state, .monotonic, .monotonic) == null)
                break;
        }

        const count_int: usize = if (count == .one) 1 else math.maxInt(usize);
        _ = syscall.wake(&self.state, count_int) catch unreachable;
    }
};
