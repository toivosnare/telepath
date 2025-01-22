const libt = @import("../root.zig");
const Channel = libt.service.Channel;
const Handle = libt.Handle;

pub const Operation = enum(u8) {
    read = 0,
    open = 1,
};

pub const Request = extern struct {
    token: u8,
    op: Operation,
    payload: Payload,

    pub const Payload = extern union {
        read: Read,
        open: Open,
    };

    pub const Read = extern struct {
        path_offset: usize,
        path_length: usize,
        buffer_offset: usize,
        n: usize,
    };

    pub const Open = extern struct {
        path_offset: usize,
        path_length: usize,
        handle: Handle,
    };
};

pub const Response = extern struct {
    token: u8,
    op: Operation,
    payload: Payload,

    pub const Payload = extern union {
        read: Read,
        open: Open,
    };

    pub const Read = usize;
    pub const Open = bool;
};

pub const DirectoryEntry = extern struct {
    name: [name_capacity]u8,
    name_length: u8,
    flags: packed struct(u8) {
        directory: bool,
        _: u7,
    },
    creation_time: DateTime,
    access_time: DateTime,
    modification_time: DateTime,
    size: u32,

    pub const name_capacity = 64;

    pub const DateTime = extern struct {
        year: u16,
        month: u8,
        day: u8,
        hours: u8,
        minutes: u8,
        seconds: u8,
    };
};

const channel_capacity = 8;
pub const buffer_capacity = 256;

pub const provide = struct {
    pub const Type = extern struct {
        request: Channel(Request, channel_capacity, .receive) = .{},
        response: Channel(Response, channel_capacity, .transmit) = .{},
        buffer: [buffer_capacity]u8 = undefined,
    };
    pub const write = true;
};

pub const consume = struct {
    pub const Type = extern struct {
        request: Channel(Request, channel_capacity, .transmit) = .{},
        response: Channel(Response, channel_capacity, .receive) = .{},
        buffer: [buffer_capacity]u8 = undefined,
    };
    pub const write = true;
};
