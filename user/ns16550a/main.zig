const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const libt = @import("libt");
const service = libt.service;
const syscall = libt.syscall;

pub const std_options = libt.std_options;

comptime {
    _ = libt;
}

extern var client: service.SerialDriver;

const Ns16550A = packed struct {
    rbr_thr: u8,
    ier: packed struct(u8) {
        data_ready: bool,
        thr_empty: bool,
        receiver_line_status: bool,
        modem_status: bool,
        _: u2 = 0,
        dma_rx_end: bool,
        dma_tx_end: bool,
    },
    iir_fcr: packed union {
        iir: packed struct(u8) {
            interrupt_status: bool,
            interrupt_identification_code: enum(u3) {
                modem_status = 0,
                thr_empty = 1,
                received_data_ready = 2,
                receiver_line_status = 3,
                reception_timeout = 6,
            },
            dma_rx_end: bool,
            dma_tx_end: bool,
            fifos_enabled: u2,
        },
        fcr: packed struct(u8) {
            fifo_enable: bool,
            rx_fifo_reset: bool,
            tx_fifo_reset: bool,
            dma_mode: bool,
            enable_dma_end: bool,
            _: u1 = 0,
            fifo_trigger_level: enum(u2) {
                tl1 = 0,
                tl4 = 1,
                tl8 = 2,
                tl14 = 3,
            },
        },
    },
    lcr: packed struct(u8) {
        word_length: enum(u2) {
            wl5 = 0,
            wl6 = 1,
            wl7 = 2,
            wl8 = 3,
        },
        stop_bits: enum(u1) {
            one = 0,
            two = 1,
        },
        parity_enable: bool,
        parity: enum(u1) {
            odd = 0,
            even = 1,
        },
        force_parity: bool,
        set_break: bool,
        dlab: bool,
    },
    mcr: packed struct(u8) {
        dtr: bool,
        rts: bool,
        _1: u1 = 0,
        interrupt_enable: bool,
        loopback: bool,
        _0: u3 = 0,
    },
    lsr: packed struct(u8) {
        data_ready: bool,
        overrun_error: bool,
        parity_error: bool,
        framing_error: bool,
        break_interrupt: bool,
        thr_empty: bool,
        transmitter_empty: bool,
        fifo_data_error: bool,
    },
    msr: packed struct(u8) {
        delta_cts: bool,
        delta_dsr: bool,
        trailing_edge_ri: bool,
        delta_dcd: bool,
        clear_to_send: bool,
        data_set_ready: bool,
        ring_indicator: bool,
        data_carrier_detect: bool,
    },
    spr: u8,

    const Self = @This();

    pub fn init(self: *volatile Self) void {
        self.lcr = .{
            .word_length = .wl8,
            .stop_bits = .one,
            .parity_enable = false,
            .parity = .odd,
            .force_parity = false,
            .set_break = false,
            .dlab = false,
        };
        self.ier = .{
            .data_ready = true,
            .thr_empty = false,
            .receiver_line_status = false,
            .modem_status = false,
            .dma_rx_end = false,
            .dma_tx_end = false,
        };
        self.iir_fcr.fcr = .{
            .fifo_enable = true,
            .rx_fifo_reset = true,
            .tx_fifo_reset = true,
            .dma_mode = false,
            .enable_dma_end = false,
            .fifo_trigger_level = .tl8,
        };
        self.mcr = .{
            .dtr = false,
            .rts = false,
            .interrupt_enable = false,
            .loopback = false,
        };
    }

    pub fn puts(self: *volatile Self, s: []const u8) void {
        for (s) |c|
            self.putc(c);
    }

    pub fn putc(self: *volatile Self, c: u8) void {
        while (!self.lsr.thr_empty) {}
        self.rbr_thr = c;
    }

    pub fn getc(self: *volatile Self) ?u8 {
        if (!self.lsr.data_ready)
            return null;
        return self.rbr_thr;
    }
};

pub fn main(args: []usize) usize {
    _ = args;

    const physical_address = 0x10000000;
    const interrupt_source = 0x0a;
    const region = syscall.regionAllocate(.self, 1, .{ .read = true, .write = true }, @ptrFromInt(physical_address)) catch unreachable;
    const ns16550a: *volatile Ns16550A = @ptrCast(syscall.regionMap(.self, region, null) catch unreachable);
    ns16550a.init();

    const tx_channel = &client.tx;
    const rx_channel = &client.rx;
    const rx_capacity = @typeInfo(@TypeOf(rx_channel)).pointer.child.capacity;
    const tx_channel_index = 0;
    const rx_channel_index = 1;
    const interrupt_index = 1;
    var signals: [2]syscall.WakeSignal = .{
        .{ .address = &tx_channel.read_index, .count = 0 },
        .{ .address = &rx_channel.write_index, .count = 0 },
    };
    var events: [2]syscall.WaitEvent = .{
        .{ .tag = .futex, .payload = .{ .futex = .{ .address = &tx_channel.write_index, .expected_value = undefined } } },
        .{ .tag = .interrupt, .payload = .{ .interrupt = interrupt_source } },
    };
    outer: while (true) {
        const tx_w = tx_channel.write_index.load(.acquire);
        const tx_r = tx_channel.read_index.load(.acquire);
        const tx_len = tx_w -% tx_r;
        const slice = tx_channel.getSliceAt(tx_r, tx_len);
        var slice_it = slice.iterator();
        while (slice_it.next()) |c| {
            ns16550a.putc(c);
        }
        tx_channel.read_index.store(tx_r +% slice.length(), .release);
        signals[tx_channel_index].count = 1;
        events[tx_channel_index].payload.futex.expected_value = tx_w;

        while (true) {
            const index = syscall.synchronize(&signals, &events, math.maxInt(usize)) catch unreachable;
            signals[tx_channel_index].count = 0;
            signals[rx_channel_index].count = 0;

            if (index == tx_channel_index) {
                syscall.unpackResult(syscall.SynchronizeError!void, events[tx_channel_index].result) catch |err| switch (err) {
                    error.WouldBlock => {},
                    else => @panic("wait errror"),
                };
                continue :outer;
            } else {
                assert(index == interrupt_index);
                assert(syscall.unpackResult(syscall.SynchronizeError!usize, events[interrupt_index].result) catch 1 == 0);

                syscall.ack(interrupt_source) catch unreachable;

                var rx_w = rx_channel.write_index.load(.acquire);
                const rx_r = rx_channel.read_index.load(.acquire);

                while (ns16550a.getc()) |c| {
                    if (rx_capacity - (rx_w -% rx_r) > 0) {
                        rx_channel.buffer[rx_w % rx_capacity] = c;
                        rx_w +%= 1;
                    }
                }
                rx_channel.write_index.store(rx_w, .release);
                signals[rx_channel_index].count = 1;
            }
        }
    }
}
