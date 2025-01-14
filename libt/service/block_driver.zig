const libt = @import("../libt.zig");
const Channel = libt.service.Channel;

pub const Request = extern struct {
    sector_index: usize,
    address: usize,
    write: bool,
    token: u8,
};

pub const Response = extern struct {
    success: bool,
    token: u8,
};

const capacity = 10;

pub const provide = struct {
    pub const Type = extern struct {
        request: Channel(Request, capacity, .receive),
        response: Channel(Response, capacity, .transmit),
    };
    pub const write = true;
};

pub const consume = struct {
    pub const Type = extern struct {
        request: Channel(Request, capacity, .transmit),
        response: Channel(Response, capacity, .receive),
    };
    pub const write = true;
};
