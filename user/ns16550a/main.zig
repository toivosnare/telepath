const std = @import("std");
const mem = std.mem;
const libt = @import("libt");
const syscall = libt.syscall;

comptime {
    _ = libt;
}

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
            .data_ready = false,
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
            .fifo_trigger_level = .tl1,
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
};

pub fn main(args: []usize) usize {
    _ = args;

    const physical_address = 0x10000000;
    const region = syscall.allocate(1, .{ .readable = true, .writable = true }, @ptrFromInt(physical_address)) catch unreachable;
    const ns16550a: *volatile Ns16550A = @ptrCast(syscall.map(region, null) catch unreachable);
    ns16550a.init();

    const stdin = @import("services").stdin;
    while (true) {
        stdin.mutex.lock();
        defer stdin.mutex.unlock();

        while (stdin.isEmpty())
            stdin.empty.wait(&stdin.mutex);

        const slice = stdin.unreadSlice();
        var it = slice.iterator();
        while (it.next()) |c| {
            ns16550a.putc(c);
        }
        stdin.read_index = (stdin.read_index + slice.length()) % libt.service.byte_stream.provide.Type.capacity;
        stdin.length -= slice.length();
    }
}
