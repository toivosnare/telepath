const libt = @import("../root.zig");
const Channel = libt.service.Channel;
const Handle = libt.Handle;

pub const Operation = enum(u8) {
    read = 0,
    seek = 1,
};

pub const Request = extern struct {
    token: u8,
    op: Operation,
    payload: Payload,

    pub const Payload = extern union {
        read: Read,
        seek: Seek,
    };

    pub const Read = extern struct {
        handle: Handle,
        offset: usize,
        n: usize,
    };

    pub const Seek = extern struct {
        offset: isize,
        whence: enum(u8) {
            set = 0,
            current = 1,
            end = 2,
        },
    };
};

pub const Response = extern struct {
    token: u8,
    op: Operation,
    payload: Payload,

    pub const Payload = extern union {
        read: Read,
        seek: Seek,
    };

    pub const Read = usize;
    pub const Seek = isize;
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
