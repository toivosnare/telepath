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
        dma_tx_end: bool,
        dma_rx_end: bool,
        _: u2 = 0,
        modem_status: bool,
        receiver_line_status: bool,
        thr_empty: bool,
        data_ready: bool,
    },
    iir_fcr: packed union {
        iir: packed struct(u8) {
            fifos_enabled: u2,
            dma_tx_end: bool,
            dma_rx_end: bool,
            interrupt_identification_code: enum(u3) {
                modem_status = 0,
                thr_empty = 1,
                received_data_ready = 2,
                receiver_line_status = 3,
                reception_timeout = 6,
            },
            interrupt_status: bool,
        },
        fcr: packed struct(u8) {
            fifo_trigger_level: enum(u2) {
                tl1 = 0,
                tl4 = 1,
                tl8 = 2,
                tl14 = 3,
            },
            _: u1 = 0,
            enable_dma_end: bool,
            dma_mode: bool,
            tx_fifo_reset: bool,
            rx_fifo_reset: bool,
            fifo_enable: bool,
        },
    },
    lcr: packed struct(u8) {
        dlab: bool,
        set_break: bool,
        force_parity: bool,
        parity: enum(u1) {
            odd = 0,
            even = 1,
        },
        parity_enable: bool,
        stop_bits: enum(u1) {
            one = 0,
            two = 1,
        },
        word_length: enum(u2) {
            wl5 = 0,
            wl6 = 1,
            wl7 = 2,
            wl8 = 3,
        },
    },
    mcr: packed struct(u8) {
        _0: u3 = 0,
        loopback: bool,
        interrupt_enable: bool,
        _1: u1 = 0,
        rts: bool,
        dtr: bool,
    },
    lsr: packed struct(u8) {
        fifo_data_error: bool,
        transmitter_empty: bool,
        thr_empty: bool,
        break_interrupt: bool,
        framing_error: bool,
        parity_error: bool,
        overrun_error: bool,
        data_ready: bool,
    },
    msr: packed struct(u8) {
        data_carrier_detect: bool,
        ring_indicator: bool,
        data_set_ready: bool,
        clear_to_send: bool,
        delta_dcd: bool,
        trailing_edge_ri: bool,
        delta_dsr: bool,
        delta_cts: bool,
    },
    spr: u8,

    const Self = @This();

    pub fn init(self: *volatile Self) void {
        _ = self;
        // self.lcr = .{
        //     .dlab = false,
        //     .set_break = false,
        //     .force_parity = false,
        //     .parity = .odd,
        //     .parity_enable = false,
        //     .stop_bits = .one,
        //     .word_length = .wl5,
        // };
        // self.ier = .{
        //     .dma_tx_end = false,
        //     .dma_rx_end = false,
        //     .modem_status = false,
        //     .receiver_line_status = false,
        //     .thr_empty = false,
        //     .data_ready = false,
        // };
        // self.iir_fcr.fcr = .{
        //     .fifo_trigger_level = .tl1,
        //     .enable_dma_end = false,
        //     .dma_mode = false,
        //     .tx_fifo_reset = true,
        //     .rx_fifo_reset = true,
        //     .fifo_enable = true,
        // };
        // self.mcr = .{
        //     .loopback = false,
        //     .interrupt_enable = false,
        //     .rts = false,
        //     .dtr = false,
        // };
    }

    pub fn puts(self: *volatile Self, s: []const u8) void {
        for (s) |c|
            self.putc(c);
    }

    pub fn putc(self: *volatile Self, c: u8) void {
        // while (!self.lsr.thr_empty) {}
        self.rbr_thr = c;
    }
};

pub fn main(args: []usize) noreturn {
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
