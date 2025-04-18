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

pub fn waitFutex(address: *atomic.Value(u32), expected_value: u32, timeout_us: usize) syscall.WaitError!void {
    var reason: [1]syscall.WaitReason = .{.{ .tag = .futex, .payload = .{ .futex = .{ .address = address, .expected_value = expected_value } } }};
    const index = try syscall.wait(&reason, timeout_us);
    assert(index == 0);
    return syscall.unpackResult(syscall.WaitError!void, reason[0].result);
}

pub fn waitThread(thread_handle: Handle, timeout_us: usize) syscall.WaitError!usize {
    var reason: [1]syscall.WaitReason = .{.{ .tag = .thread, .payload = .{ .thread = thread_handle } }};
    const index = try syscall.wait(&reason, timeout_us);
    assert(index == 0);
    return syscall.unpackResult(syscall.WaitError!usize, reason[0].result);
}

pub fn waitInterrupt(source: u32, timeout_us: usize) syscall.WaitError!void {
    var reason: [1]syscall.WaitReason = .{.{ .tag = .interrupt, .payload = .{ .interrupt = source } }};
    const index = try syscall.wait(&reason, timeout_us);
    assert(index == 0);
    return syscall.unpackResult(syscall.WaitError!void, reason[0].result);
}

pub fn sleep(us: usize) syscall.WaitError!void {
    _ = syscall.wait(null, us) catch |err| switch (err) {
        error.Timeout => return,
        else => return err,
    };
    unreachable;
}

const std = @import("std");
const assert = std.debug.assert;
const atomic = std.atomic;
