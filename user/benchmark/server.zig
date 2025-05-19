const std = @import("std");
const math = std.math;
const mem = std.mem;
const libt = @import("libt");
const service = libt.service;
const syscall = libt.syscall;
const interface = @import("interface.zig");

pub const os = libt;
pub const std_options = libt.std_options;

comptime {
    _ = libt;
}

extern var control: interface.Control;

const Client = struct {
    rpc_buffer: *interface.Data,
    signal: syscall.WakeSignal,
    event: syscall.WaitEvent,
};

var clients: std.MultiArrayList(Client) = .empty;

pub fn main(args: []usize) !void {
    _ = args;

    var gpa_state: std.heap.DebugAllocator(.{
        .thread_safe = false,
        .safety = false,
    }) = .init;
    const gpa = gpa_state.allocator();

    try clients.append(gpa, .{
        .rpc_buffer = undefined,
        .signal = .{
            .address = @ptrCast(&control.register.turn),
            .count = 0,
        },
        .event = .{
            .tag = .futex,
            .payload = .{ .futex = .{
                .address = @ptrCast(&control.register.turn),
                .expected_value = undefined,
            } },
        },
    });

    var spin_estimate: isize = 128;
    const spin_limit_max = 512;
    const spin_decay_rate = 4;

    while (true) {
        try handleControlClient(gpa);

        const rpc_buffers = clients.items(.rpc_buffer);
        const signals = clients.items(.signal);
        const events = clients.items(.event);

        const spin_limit: isize = @min(2 * spin_estimate, spin_limit_max);
        var spin_count: isize = 0;

        while (spin_count < spin_limit) {
            var found_work: bool = false;
            for (rpc_buffers[1..], signals[1..], events[1..]) |rpc_buffer, *signal, *event| {
                found_work = handleDataClient(rpc_buffer, signal, event) or found_work;
            }
            if (found_work) {
                spin_estimate += @divTrunc(spin_count - spin_estimate, spin_decay_rate);
                spin_count = 0;
            } else {
                spin_count += 1;
            }
        }
        spin_estimate += @divTrunc(spin_limit - spin_estimate, spin_decay_rate);

        const event_index = syscall.synchronize(signals, events, math.maxInt(usize)) catch |err| switch (err) {
            else => unreachable,
        };
        syscall.unpackResult(syscall.SynchronizeError!void, events[event_index].result) catch |err| switch (err) {
            error.WouldBlock => {},
            else => @panic("wait error"),
        };
        for (signals) |*signal|
            signal.count = 0;
    }
}

fn handleControlClient(gpa: mem.Allocator) !void {
    var turn = control.register.turn.load(.acquire);

    if (turn == .server) {
        const rpc_buffer: *interface.Data = @ptrCast(try syscall.regionMap(.self, control.register.request, null));
        rpc_buffer.response[0] = 0;
        try clients.append(gpa, .{
            .rpc_buffer = rpc_buffer,
            .signal = .{
                .address = @ptrCast(&rpc_buffer.turn),
                .count = 0,
            },
            .event = .{
                .tag = .futex,
                .payload = .{ .futex = .{
                    .address = @ptrCast(&rpc_buffer.turn),
                    .expected_value = undefined,
                } },
            },
        });

        turn = .client;
        control.register.turn.store(turn, .release);
        clients.items(.signal)[0].count = 1;
    }

    clients.items(.event)[0].payload.futex.expected_value = @intFromEnum(turn);
}

fn handleDataClient(
    rpc_buffer: *interface.Data,
    signal: *syscall.WakeSignal,
    event: *syscall.WaitEvent,
) bool {
    var turn = rpc_buffer.turn.load(.acquire);
    var result = false;

    if (turn == .server) {
        @memcpy(&rpc_buffer.response, &rpc_buffer.request);
        turn = .client;
        rpc_buffer.turn.store(turn, .release);
        result = true;
        signal.count = 1;
    }

    event.payload.futex.expected_value = @intFromEnum(turn);
    return result;
}
