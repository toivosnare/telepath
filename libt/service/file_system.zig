const libt = @import("../libt.zig");
const Channel = libt.service.Channel;

pub const Operation = enum(u8) {
    read = 0,
    change_working_directory = 1,
};

pub const Request = extern struct {
    token: u8,
    op: Operation,
    payload: Payload,

    pub const Payload = extern union {
        read: Read,
        change_working_directory: ChangeWorkingDirectory,
    };

    pub const Read = extern struct {
        buffer_offset: usize,
        n: usize,
    };

    pub const ChangeWorkingDirectory = extern struct {
        path_offset: usize,
        path_length: usize,
    };
};

pub const Response = extern struct {
    token: u8,
    op: Operation,
    payload: Payload,

    pub const Payload = extern union {
        read: Read,
        change_working_directory: ChangeWorkingDirectory,
    };

    pub const Read = usize;
    pub const ChangeWorkingDirectory = isize;
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
        request: Channel(Request, channel_capacity, .bidirectional) = .{},
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
