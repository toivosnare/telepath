const libt = @import("../root.zig");
const Channel = libt.service.Channel;
const Handle = libt.Handle;

pub const Operation = enum(u8) {
    read = 0,
    write = 1,
    seek = 2,
    close = 3,
};

pub const Request = extern struct {
    token: u8,
    op: Operation,
    payload: Payload,

    pub const Payload = extern union {
        read: Read,
        write: Write,
        seek: Seek,
        close: Close,
    };

    pub const Read = extern struct {
        handle: Handle,
        offset: usize,
        n: usize,
    };

    pub const Write = extern struct {
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

    pub const Close = extern struct {};
};

pub const Response = extern struct {
    token: u8,
    op: Operation,
    payload: Payload,

    pub const Payload = extern union {
        read: Read,
        write: Write,
        seek: Seek,
        close: Close,
    };

    pub const Read = usize;
    pub const Write = usize;
    pub const Seek = isize;
    pub const Close = void;
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
