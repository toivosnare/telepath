const libt = @import("../libt.zig");
const Channel = libt.service.Channel;

// Fits in one page.
const capacity = 2004;

comptime {
    const assert = @import("std").debug.assert;
    assert(@sizeOf(provide.Type) == 4096);
    assert(@sizeOf(consume.Type) == 4096);
}

pub const provide = struct {
    pub const Type = extern struct {
        tx: Channel(u8, capacity, .receive),
        rx: Channel(u8, capacity, .transmit),
    };
    pub const write = true;
};

pub const consume = struct {
    pub const Type = extern struct {
        tx: Channel(u8, capacity, .transmit),
        rx: Channel(u8, capacity, .receive),
    };
    pub const write = true;
};
