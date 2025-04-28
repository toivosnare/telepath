const libt = @import("../root.zig");
const Channel = libt.service.Channel;

pub const BlockDriver = extern struct {
    request: Channel(Request, channel_capacity, .transmit),
    response: Channel(Response, channel_capacity, .receive),

    pub const channel_capacity = 10;

    pub const Request = extern struct {
        sector_index: usize,
        address: usize,
        write: bool,
        token: usize,
    };

    pub const Response = extern struct {
        success: bool,
        token: usize,
    };
};
