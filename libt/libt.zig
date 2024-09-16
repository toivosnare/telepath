pub const heap = @import("heap.zig");
pub const service = @import("service.zig");
pub const sync = @import("sync.zig");
pub const syscall = @import("syscall.zig");
pub const tix = @import("tix.zig");

pub const address_space_end = 0x4000000000;

comptime {
    if (@import("builtin").os.tag == .freestanding)
        _ = @import("start.zig");
}

pub fn waitFutex(address: *atomic.Value(u32), expected_value: u32, timeout_ns: usize) syscall.WaitError!void {
    var reason: [1]syscall.WaitReason = .{.{ .tag = .futex, .payload = .{ .futex = .{ .address = address, .expected_value = expected_value } } }};
    const index = try syscall.wait(&reason, false, timeout_ns);
    assert(index == 0);
    _ = try syscall.unpackResult(syscall.WaitError, reason[0].result);
}

pub fn waitChildProcess(pid: usize, timeout_ns: usize) syscall.WaitError!usize {
    var reason: [1]syscall.WaitReason = .{.{ .tag = .child_process, .payload = .{ .child_process = .{ .pid = pid } } }};
    const index = try syscall.wait(&reason, false, timeout_ns);
    assert(index == 0);
    return syscall.unpackResult(syscall.WaitError, reason[0].result);
}

pub fn sleep(ns: usize) syscall.WaitError!void {
    _ = syscall.wait(null, false, ns) catch |err| switch (err) {
        error.Timeout => return,
        else => return err,
    };
    unreachable;
}

const std = @import("std");
const assert = std.debug.assert;
const atomic = std.atomic;
