const std = @import("std");
const assert = std.debug.assert;
const libt = @import("../root.zig");
const Channel = libt.service.Channel;

pub const Timestamp = Response.Timestamp;
pub const DateTime = Response.DateTime;

pub const Operation = enum(u8) {
    timestamp = 0,
    date_time = 1,
};

pub const Request = extern struct {
    token: u8,
    op: Operation,
    payload: Payload,

    pub const Payload = extern union {
        timestamp: Request.Timestamp,
        date_time: Request.DateTime,
    };

    pub const Timestamp = extern struct {};
    pub const DateTime = extern struct {};
};

pub const Response = extern struct {
    token: u8,
    op: Operation,
    payload: Payload,

    pub const Payload = extern union {
        timestamp: Response.Timestamp,
        date_time: Response.DateTime,
    };

    pub const Timestamp = u64;
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

        pub fn currentTimestamp(self: *@This()) Timestamp {
            self.request.write(.{
                .token = 0,
                .op = .timestamp,
                .payload = .{ .timestamp = .{} },
            });
            const response = self.response.read();
            assert(response.token == 0);
            return response.payload.timestamp;
        }

        pub fn currentDateTime(self: *@This()) DateTime {
            self.request.write(.{
                .token = 0,
                .op = .date_time,
                .payload = .{ .date_time = .{} },
            });
            const response = self.response.read();
            assert(response.token == 0);
            return response.payload.date_time;
        }
    };
    pub const write = true;
};
