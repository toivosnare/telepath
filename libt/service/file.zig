const std = @import("std");
const assert = std.debug.assert;
const libt = @import("../root.zig");
const syscall = libt.syscall;
const Channel = libt.service.Channel;
const Handle = libt.Handle;

pub const File = extern struct {
    request: Channel(Request, channel_capacity, .transmit),
    response: Channel(Response, channel_capacity, .receive),

    pub const channel_capacity = 8;

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
            whence: Whence,

            pub const Whence = enum(u8) {
                set = 0,
                current = 1,
                end = 2,
            };
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

    pub fn read(self: *File, handle: Handle, offset: usize, n: usize) usize {
        self.request.write(.{
            .token = 0,
            .op = .read,
            .payload = .{ .read = .{
                .handle = handle,
                .offset = offset,
                .n = n,
            } },
        });
        const response = self.response.read();
        assert(response.token == 0);
        return response.payload.read;
    }

    pub fn write(self: *File, handle: Handle, offset: usize, n: usize) usize {
        self.request.write(.{
            .token = 0,
            .op = .write,
            .payload = .{ .write = .{
                .handle = handle,
                .offset = offset,
                .n = n,
            } },
        });
        const response = self.response.read();
        assert(response.token == 0);
        return response.payload.write;
    }

    pub fn seek(self: *File, offset: isize, whence: Request.Seek.Whence) isize {
        self.request.write(.{
            .token = 0,
            .op = .seek,
            .payload = .{ .seek = .{
                .offset = offset,
                .whence = whence,
            } },
        });
        const response = self.response.read();
        assert(response.token == 0);
        return response.payload.seek;
    }

    pub fn close(self: *File) void {
        self.request.write(.{
            .token = 0,
            .op = .close,
            .payload = .{ .close = .{} },
        });
        const response = self.response.read();
        assert(response.token == 0);
    }

    pub fn closeFile(self: *File) void {
        self.close();
        const handle = syscall.regionUnmap(.self, @alignCast(@ptrCast(self))) catch unreachable;
        syscall.regionFree(.self, handle) catch {};
    }
};
