const libt = @import("../root.zig");
const Channel = libt.service.Channel;
const Handle = libt.Handle;

pub const Operation = enum(u8) {
    read = 0,
};

pub const Request = extern struct {
    token: u8,
    op: Operation,
    payload: Payload,

    pub const Payload = extern union {
        read: Read,
    };

    pub const Read = extern struct {
        handle: Handle,
        offset: usize,
        n: usize,
    };
};

pub const Response = extern struct {
    token: u8,
    op: Operation,
    payload: Payload,

    pub const Payload = extern union {
        read: Read,
    };

    pub const Read = usize;
};

const channel_capacity = 8;

pub const provide = struct {
    pub const Type = extern struct {
        request: Channel(Request, channel_capacity, .receive) = .{},
        response: Channel(Response, channel_capacity, .transmit) = .{},
    };
    pub const write = true;
};

pub const consume = struct {
    pub const Type = extern struct {
        request: Channel(Request, channel_capacity, .transmit) = .{},
        response: Channel(Response, channel_capacity, .receive) = .{},
    };
    pub const write = true;
};
