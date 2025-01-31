const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const libt = @import("../root.zig");
const syscall = libt.syscall;
const DateTime = libt.service.RtcDriver.DateTime;
const Channel = libt.service.Channel;
const File = libt.service.File;
const Handle = libt.Handle;
const Directory = @This();

request: Channel(Request, channel_capacity, .transmit),
response: Channel(Response, channel_capacity, .receive),
buffer: [buffer_capacity]u8 = undefined,

pub const channel_capacity = 8;
pub const buffer_capacity = 256;

pub const Operation = enum(u8) {
    read = 0,
    seek = 2,
    close = 3,
    open = 4,
    stat = 5,
    sync = 6,
};

pub const Request = extern struct {
    token: u8,
    op: Operation,
    payload: Payload,

    pub const Payload = extern union {
        read: Read,
        seek: Seek,
        close: Close,
        open: Open,
        stat: Stat,
        sync: Sync,
    };

    pub const Read = extern struct {
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
        };
    };

    pub const Close = extern struct {};

    pub const Open = extern struct {
        path_offset: usize,
        path_length: usize,
        handle: Handle,
        kind: Kind,

        pub const Kind = enum(u8) {
            any = 0,
            directory = 1,
            file = 2,
        };
    };

    pub const Stat = extern struct {
        path_offset: usize,
        path_length: usize,
        region_handle: Handle,
        region_offset: usize,
    };

    pub const Sync = extern struct {};
};

pub const Response = extern struct {
    token: u8,
    op: Operation,
    payload: Payload,

    pub const Payload = extern union {
        read: Read,
        seek: Seek,
        close: Close,
        open: Open,
        stat: Stat,
        sync: Sync,
    };

    pub const Read = usize;
    pub const Seek = isize;
    pub const Close = void;
    pub const Open = bool;
    pub const Stat = bool;
    pub const Sync = void;
};

pub const Entry = extern struct {
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
};

pub fn read(self: *Directory, handle: Handle, offset: usize, n: usize) usize {
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

pub fn seek(self: *Directory, offset: isize, whence: Request.Seek.Whence) isize {
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

pub fn close(self: *Directory) void {
    self.request.write(.{
        .token = 0,
        .op = .close,
        .payload = .{ .close = .{} },
    });
    const response = self.response.read();
    assert(response.token == 0);
}

pub fn closeDirectory(self: *Directory) void {
    self.close();
    const handle = syscall.regionUnmap(.self, @alignCast(@ptrCast(self))) catch unreachable;
    syscall.regionFree(.self, handle) catch {};
}

pub fn open(self: *Directory, path_offset: usize, path_length: usize, handle: Handle, kind: Request.Open.Kind) bool {
    self.request.write(.{
        .token = 0,
        .op = .open,
        .payload = .{ .open = .{
            .path_offset = path_offset,
            .path_length = path_length,
            .handle = handle,
            .kind = kind,
        } },
    });
    const response = self.response.read();
    assert(response.token == 0);
    return response.payload.open;
}

pub fn openDirectory(self: *Directory, path: []const u8, fs_handle: Handle) !*Directory {
    const size = math.divCeil(usize, @sizeOf(Directory), mem.page_size) catch unreachable;
    const handle = try syscall.regionAllocate(.self, size, .{ .read = true, .write = true }, null);
    errdefer syscall.regionFree(.self, handle) catch {};
    const shared_handle = try syscall.regionShare(.self, handle, fs_handle, .{ .read = true, .write = true });

    @memcpy(self.buffer[0..path.len], path);
    if (!self.open(0, path.len, shared_handle, .directory))
        return error.Failed;

    return @ptrCast(try syscall.regionMap(.self, handle, null));
}

pub fn openFile(self: *Directory, path: []const u8, fs_handle: Handle) !*File {
    const size = math.divCeil(usize, @sizeOf(File), mem.page_size) catch unreachable;
    const handle = try syscall.regionAllocate(.self, size, .{ .read = true, .write = true }, null);
    errdefer syscall.regionFree(.self, handle) catch {};
    const shared_handle = try syscall.regionShare(.self, handle, fs_handle, .{ .read = true, .write = true });

    @memcpy(self.buffer[0..path.len], path);
    if (!self.open(0, path.len, shared_handle, .file))
        return error.Failed;

    return @ptrCast(try syscall.regionMap(.self, handle, null));
}

pub fn stat(self: *Directory, path: []const u8, handle: Handle, offset: usize) bool {
    @memcpy(self.buffer[0..path.len], path);
    self.request.write(.{
        .token = 0,
        .op = .stat,
        .payload = .{ .stat = .{
            .path_offset = 0,
            .path_length = path.len,
            .region_handle = handle,
            .region_offset = offset,
        } },
    });
    const response = self.response.read();
    assert(response.token == 0);
    return response.payload.stat;
}

pub fn sync(self: *Directory) void {
    self.request.write(.{
        .token = 0,
        .op = .sync,
        .payload = .{ .sync = .{} },
    });
    const response = self.response.read();
    assert(response.token == 0);
}
