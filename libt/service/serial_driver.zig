const libt = @import("../root.zig");
const Channel = libt.service.Channel;

pub const SerialDriver = extern struct {
    tx: Channel(u8, capacity, .transmit),
    rx: Channel(u8, capacity, .receive),
};

// Fits in one page.
const capacity = 2004;

comptime {
    const std = @import("std");
    std.debug.assert(@sizeOf(@This()) == 4096);
}
