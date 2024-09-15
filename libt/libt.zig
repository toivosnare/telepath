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
    _ = syscall.wait(&.{ .tag = .futex, .payload = .{ .futex = .{ .address = address, .expected_value = expected_value } } }, timeout_ns) catch |err| return err;
}

pub fn waitChildProcess(pid: usize, timeout_ns: usize) syscall.WaitError!usize {
    return syscall.wait(&.{ .tag = .child_process, .payload = .{ .child_process = .{ .pid = pid } } }, timeout_ns);
}

pub fn sleep(ns: usize) syscall.WaitError!void {
    _ = syscall.wait(null, ns) catch |err| switch (err) {
        error.Timeout => {},
        else => return err,
    };
}

const std = @import("std");
const atomic = std.atomic;
