const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const libt = @import("libt");
const service = libt.service;
const syscall = libt.syscall;
const Handle = libt.Handle;
const interface = @import("interface.zig");

pub const std_options = libt.std_options;

comptime {
    _ = libt;
}

extern var control: interface.Control;
extern var serial: service.SerialDriver;
const writer = serial.tx.writer();

pub fn main(args: []usize) !void {
    try writer.writeAll("Benchmark starting.\n");

    const page_size = std.heap.pageSize();
    const server: Handle = @enumFromInt(args[0]);

    for (0..interface.client_count) |client_index| {
        const region = try syscall.regionAllocate(.self, 1, .{ .read = true, .write = true }, null);
        const region_ptr = try syscall.regionMap(.self, region, null);
        const region_shared = try syscall.regionShare(.self, region, server, .{ .read = true, .write = true });
        control.register.request = region_shared;
        control.register.call();

        const stack_pages = 16;
        const stack_handle = try syscall.regionAllocate(.self, stack_pages, .{ .read = true, .write = true }, null);
        const stack_start: [*]align(page_size) u8 = @ptrCast(try syscall.regionMap(.self, stack_handle, null));
        const stack_end = stack_start + stack_pages * page_size;
        _ = try syscall.threadAllocate(.self, .self, &client, stack_end, 6, client_index, @intFromPtr(region_ptr));
    }
}

fn client(client_index: usize, rpc_buffer: *interface.Data) callconv(.c) noreturn {
    var bw = std.io.bufferedWriter(writer);
    const buffered_writer = bw.writer();

    rpc_buffer.init();

    var ready_count = control.ready_count.fetchAdd(1, .monotonic) + 1;
    while (ready_count < interface.client_count) {
        ready_count = control.ready_count.load(.monotonic);
    }

    var sample_index: usize = 0;
    while (true) {
        for (&rpc_buffer.request) |*w|
            w.* = rand();

        const start_time = libt.readTime();
        rpc_buffer.call();
        const end_time = libt.readTime();

        assert(mem.eql(u8, mem.asBytes(&rpc_buffer.request), mem.asBytes(&rpc_buffer.response)));

        if (sample_index < interface.sample_count) {
            const delta: usize = end_time - start_time;
            control.samples[client_index][sample_index] = @intCast(delta);
            sample_index += 1;
            if (sample_index == interface.sample_count) {
                _ = control.finished_count.fetchAdd(1, .monotonic);
            } else {
                continue;
            }
        }
        if (control.finished_count.load(.monotonic) == interface.client_count) {
            break;
        }
    }

    if (client_index != 0) {
        syscall.exit(0);
    }

    for (0..interface.client_count) |ci| {
        buffered_writer.print("Client {d}:\n", .{ci}) catch unreachable;
        for (0..interface.sample_count) |si| {
            buffered_writer.print("{d}\n", .{control.samples[ci][si]}) catch unreachable;
        }
    }
    bw.flush() catch unreachable;

    syscall.exit(0);
}

// Generates a pseudo-random number with a linear congruential generator.
var lcg_x: usize = 1;

fn rand() usize {
    const a = 1664525;
    const c = 1013904223;
    const m = 4294967296;
    lcg_x = (a * lcg_x + c) % m;
    return lcg_x;
}
