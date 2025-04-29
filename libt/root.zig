pub const heap = @import("heap.zig");
pub const service = @import("service.zig");
pub const sync = @import("sync.zig");
pub const syscall = @import("syscall.zig");
pub const tix = @import("tix.zig");

pub const address_space_end = 0x4000000000;
pub const Handle = enum(u64) {
    self = 0,
    _,
};

pub const std_options: std.Options = .{
    .page_size_min = 1 << 12,
    .page_size_max = 1 << 12,
};

comptime {
    if (@import("builtin").os.tag == .freestanding)
        _ = @import("start.zig");
}

pub fn wake(wake_addr: *atomic.Value(u32), count: usize) syscall.SynchronizeError!usize {
    const signal: syscall.WakeSignal = .{
        .address = wake_addr,
        .count = count,
    };
    return syscall.synchronize((&signal)[0..1], null, 0);
}

pub fn waitFutex(address: *atomic.Value(u32), expected_value: u32, timeout_us: ?usize) syscall.SynchronizeError!void {
    var event: syscall.WaitReason = .{
        .tag = .futex,
        .payload = .{ .futex = .{
            .address = address,
            .expected_value = expected_value,
        } },
    };
    const index = try syscall.synchronize(null, (&event)[0..1], if (timeout_us) |t| t else math.maxInt(usize));
    assert(index == 0);
    return syscall.unpackResult(syscall.SynchronizeError!void, event.result);
}

pub fn waitThread(thread_handle: Handle, timeout_us: ?usize) syscall.SynchronizeError!usize {
    var event: syscall.WaitReason = .{
        .tag = .thread,
        .payload = .{ .thread = thread_handle },
    };
    const index = try syscall.synchronize(null, (&event)[0..1], if (timeout_us) |t| t else math.maxInt(usize));
    assert(index == 0);
    return syscall.unpackResult(syscall.SynchronizeError!void, event.result);
}

pub fn waitInterrupt(source: u32, timeout_us: ?usize) syscall.SynchronizeError!void {
    var event: syscall.WaitReason = .{
        .tag = .interrupt,
        .payload = .{ .interrupt = source },
    };
    const index = try syscall.synchronize(null, (&event)[0..1], if (timeout_us) |t| t else math.maxInt(usize));
    assert(index == 0);
    return syscall.unpackResult(syscall.SynchronizeError!void, event.result);
}

pub fn sleep(timeout_us: ?usize) syscall.SynchronizeError!void {
    _ = syscall.synchronize(null, null, if (timeout_us) |t| t else math.maxInt(usize)) catch |err| switch (err) {
        error.Timeout => return,
        else => return err,
    };
    unreachable;
}

pub fn waitMultiple(events: []syscall.WaitReason, timeout_us: ?usize) syscall.SynchronizeError!usize {
    return syscall.synchronize(null, events, if (timeout_us) |t| t else math.maxInt(usize));
}

pub fn call(wake_addr: *atomic.Value(u32), wait_addr: *atomic.Value(u32), expected_value: u32, timeout_us: ?usize) syscall.SynchronizeError!usize {
    const signal: syscall.WakeSignal = .{
        .address = wake_addr,
        .count = 1,
    };
    var event: syscall.WaitReason = .{
        .tag = .futex,
        .payload = .{ .futex = .{
            .address = wait_addr,
            .expected_value = expected_value,
        } },
    };
    return syscall.synchronize((&signal)[0..1], (&event)[0..1], if (timeout_us) |t| t else math.maxInt(usize));
}

const std = @import("std");
const assert = std.debug.assert;
const atomic = std.atomic;
const math = std.math;
