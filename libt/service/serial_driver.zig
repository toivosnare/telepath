const libt = @import("../root.zig");
const Fifo = libt.service.Fifo;

pub const SerialDriver = extern struct {
    tx: Fifo(u8, capacity, true, false, .write_only),
    rx: Fifo(u8, capacity, false, true, .read_only),
};

const capacity = 1024;
