const libt = @import("../libt.zig");
const Channel = libt.service.Channel;

// Fits in one page.
const capacity = 4048;

pub const provide = struct {
    pub const Type = Channel(u8, capacity, .receive);
    pub const write = true;
};

pub const consume = struct {
    pub const Type = Channel(u8, capacity, .transmit);
    pub const write = true;
};
